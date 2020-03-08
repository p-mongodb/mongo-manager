autoload :FileUtils, 'fileutils'
autoload :Pathname, 'pathname'
autoload :Find, 'find'

module MongoManager
  class Executor
    def initialize(**opts)
      @options = opts

      unless options[:dir]
        raise ArgumentError, ':dir option must be given'
      end

      if options[:username] && !options[:password]
        raise ArgumentError, ':username and :password must be given together'
      end

      if options[:arbiter] && !options[:replica_set]
        raise ArgumentError, ':arbiter option requires :replica_set'
      end

      if options[:data_bearing_nodes] && !options[:replica_set]
        raise ArgumentError, ':data_bearing_nodes option requires :replica_set'
      end

      @client_log_level = :warn
      Mongo::Logger.level = client_log_level

      @common_args = []
    end

    attr_reader :options
    attr_reader :config
    attr_reader :client_log_level
    attr_reader :common_args

    def init
      FileUtils.mkdir_p(root_dir)
      create_config

      if sharded?
        init_sharded
      elsif options[:replica_set]
        init_rs
      else
        init_standalone
      end
    rescue => e
      log_paths = []
      Find.find(root_dir) do |path|
        if path.end_with?('.log')
          log_paths << path
        end
      end
      if log_paths.any?
        log_paths.sort!
        msg = "#{e.class}: #{e}"
        log_paths.each do |log_path|
          excerpt = Helper.excerpt_log_file(log_path)
          msg = "#{msg}\n\n#{excerpt}"
        end
        begin
          new_exc = e.class.new(msg)
        rescue
          # If we cannot create an exception instance of the same class
          # with the augmented message, reraise the original exception
          raise e
        end
        new_exc.set_backtrace(e.backtrace)
        raise new_exc
      else
        raise
      end
    end

    def start
      read_config

      do_start
    end

    private def do_start
      config[:db_dirs].each do |db_dir|
        cmd = config[:settings][db_dir][:start_cmd]
        Helper.spawn_mongo(*cmd)
      end
    end

    def stop
      read_config

      do_stop
    end

    private def do_stop
      pids = {}

      config[:db_dirs].reverse.each do |db_dir|
        binary_basename = File.basename(config[:settings][db_dir][:start_cmd].first)
        pid_file_path = File.join(db_dir, "#{binary_basename}.pid")
        if File.exist?(pid_file_path)
          pid = File.read(pid_file_path).strip.to_i
          puts("Sending TERM to pid #{pid} for #{db_dir}")
          begin
            Process.kill('TERM', pid)
          rescue Errno::ESRCH
            # No such process
          else
            # In a sharded cluster, the order in which processes are killed
            # matters: if the config server is killed before shards, the shards
            # will wait a long time for the config server. Thus kill the
            # processes in reverse order of starting and wait for each
            # process before proceeding to the next one. In other topologies
            # we can kill all processes and then wait for them all to die.
            if config[:sharded]
              do_wait(db_dir, pid)
            else
              pids[db_dir] = pid
            end
          end
        end
      end

      pids.each do |db_dir, pid|
        do_wait(db_dir, pid)
      end
    end

    private

    def do_wait(db_dir, pid)
      binary_basename = File.basename(config[:settings][db_dir][:start_cmd].first)
      Helper.wait_for_pid(db_dir, pid, 15, binary_basename)
    end

    def create_config
      if sharded?
        @config = {
          db_dirs: [],
          sharded: num_shards,
          mongos: num_mongos,
        }
      elsif options[:replica_set]
        @config = {
          db_dirs: [],
        }
      else
        @config = {
          db_dirs: [],
        }
      end
      write_config
    end

    def write_config
      File.open(root_dir.join('mongo-manager.yml'), 'w') do |f|
        f << YAML.dump(config)
      end
    end

    def read_config
      @config = YAML.load(File.read(File.join(root_dir, 'mongo-manager.yml')))
    end

    def init_standalone
      dir = root_dir.join('standalone')
      spawn_standalone(dir, base_port, mongod_passthrough_args)

      if options[:username]
        client = Mongo::Client.new(["localhost:#{base_port}"],
          client_tls_options.merge(
            connect: :direct, database: 'admin'))
        create_user(client)
        client.close

        do_stop

        spawn_standalone(dir, base_port, %w(--auth) + mongod_passthrough_args)
      end

      write_config
    end

    def init_rs
      maybe_create_key

      server_addresses = []
      1.upto(num_data_bearing_nodes) do |i|
        port = base_port - 1 + i
        dir = root_dir.join("rs#{i}")

        spawn_replica_set_node(dir, port, options[:replica_set],
          common_args + mongod_passthrough_args)

        server_addresses << "localhost:#{port}"
      end

      if options[:arbiter]
        port = base_port + num_data_bearing_nodes
        dir = root_dir.join('arbiter')

        spawn_replica_set_node(dir, port, options[:replica_set],
          common_args + mongod_passthrough_args)

        arbiter_address = "localhost:#{port}"
      end

      write_config

      initiate_replica_set(server_addresses, options[:replica_set], arbiter: arbiter_address)

      puts("Waiting for replica set to initialize")
      client = Mongo::Client.new(["localhost:#{base_port}"],
        client_tls_options.merge(
          replica_set: options[:replica_set], database: 'admin'))
      client.database.command(ping: 1)

      if options[:username]
        create_user(client)
        client.close

        stop
        start

        client = Mongo::Client.new(["localhost:#{base_port}"],
          client_tls_options.merge(
            replica_set: options[:replica_set], database: 'admin',
            user: options[:username], password: options[:password],
          ),
        )
        client.database.command(ping: 1)
      end

      client.close
    end

    def init_sharded
      maybe_create_key

      if options[:csrs] || server_version >= Gem::Version.new('3.4')
        spawn_replica_set_node(
          root_dir.join('csrs'),
          base_port + num_mongos,
          'csrs',
          common_args + %w(--configsvr) + config_server_passthrough_args,
        )

        initiate_replica_set(%W(localhost:#{base_port+num_mongos}), 'csrs', config_server: true)

        config_db_opt = "csrs/localhost:#{base_port+num_mongos}"
      else
        spawn_standalone(root_dir.join('csrs'), base_port + num_mongos,
          common_args + %w(--configsvr) + config_server_passthrough_args)

        config_db_opt = "localhost:#{base_port+num_mongos}"
      end

      shard_base_port = base_port + num_mongos + 1

      1.upto(num_shards) do |shard|
        shard_name = 'shard%02d' % shard
        port = shard_base_port - 1 + shard
        spawn_replica_set_node(
          root_dir.join(shard_name),
          port,
          shard_name,
          common_args + %w(--shardsvr) + mongod_passthrough_args,
        )

        initiate_replica_set(%W(localhost:#{port}), shard_name)
      end

      1.upto(num_mongos) do |mongos|
        port = base_port - 1 + mongos
        dir = root_dir.join('router%02d' % mongos)
        puts("Spawn mongos on port #{port}")
        FileUtils.mkdir(dir)
        cmd = [
          mongo_path('mongos'),
          dir.join('mongos.log').to_s,
          dir.join('mongos.pid').to_s,
          '--port', port.to_s,
          '--configdb', config_db_opt,
        ] + server_tls_args + common_args +
          passthrough_args + (options[:mongos_passthrough_args] || [])
        Helper.spawn_mongo(*cmd)
        record_start_command(dir, cmd)
      end

      write_config

      client = Mongo::Client.new(["localhost:#{base_port}"],
        client_tls_options.merge(database: 'admin'))
      1.upto(num_shards) do |shard|
        replica_set_name = "shard#{'%02d' % shard}"
        host = "localhost:#{base_port+num_mongos+shard}"
        # Old servers (e.g. 2.6) fail if the replica set is not waited for
        # before trying to add it as a shard.
        puts("Waiting for replica set at #{host}")
        shard_client = Mongo::Client.new([host], client_tls_options.merge(
          replica_set: replica_set_name))
        begin
          shard_client.database.command(ping: 1)
        ensure
          shard_client.close
        end
        shard_str = "#{replica_set_name}/#{host}"
        puts("Adding shard #{shard_str}")
        client.database.command(
          addShard: shard_str,
        )
      end

      if options[:username]
        create_user(client)
      end

      client.close
    end

    def initiate_replica_set(hosts, replica_set_name, **opts)
      # replSetInitiate fails immediately if any of the hosts are not
      # available; wait for them to come up
      hosts.each do |host|
        puts("Waiting for #{host} to start")
        client = Mongo::Client.new([host],
          client_tls_options.merge(connect: :direct))
        begin
          client.database.command(ping: 1)
        ensure
          client.close
        end
      end

      members = []
      hosts.each_with_index do |host, index|
        members << { _id: index, host: host }
      end

      if opts[:arbiter]
        members << {_id: hosts.length, host: opts[:arbiter], arbiterOnly: true}
      end

      rs_config = {
        _id: replica_set_name,
        members: members,
      }

      if opts[:config_server]
        rs_config[:configsvr] = true
      end

      msg = "Initiating replica set #{replica_set_name}/#{hosts.join(',')}"
      if opts[:arbiter]
        msg += "+#{opts[:arbiter]}"
      end
      puts(msg)
      direct_client(hosts.first) do |client|
        client.database.command(replSetInitiate: rs_config)
      end

      deadline = Time.now + 30
      hosts.each do |host|
        puts "Waiting for #{host} to provision"
        direct_client(host) do |client|
          loop do
            server = client.cluster.servers_list.first
            puts server.summary
            if server.primary? || server.secondary?
              break
            end
            if Time.now > deadline
              raise "Node #{server.summary} failed to provision"
            end
            sleep 1
            server.scan!
          end
        end
      end
    end

    def maybe_create_key
      if options[:username]
        key_file_path = root_dir.join('.key')
        Helper.create_key(key_file_path)
        @common_args += ['--keyFile', key_file_path.to_s]
      end
    end

    def create_user(client)
      client.database.users.create(
        options[:username],
        password: options[:password],
        roles: %w(root),
      )
    end

    def root_dir
      @root_dir ||= Pathname.new(options[:dir]).freeze
    end

    def base_port
      @base_port ||= options[:base_port] || 27017
    end

    def passthrough_args
      options[:passthrough_args] || []
    end

    def mongod_passthrough_args
      options[:mongod_passthrough_args] || []
    end

    def mongos_passthrough_args
      options[:mongos_passthrough_args] || []
    end

    def config_server_passthrough_args
      options[:config_server_passthrough_args] || []
    end

    def sharded?
      !!(options[:mongos] || options[:sharded])
    end

    def num_shards
      unless sharded?
        raise ArgumentError, "Not in a sharded topology"
      end
      options[:sharded] || 1
    end

    def num_mongos
      unless sharded?
        raise ArgumentError, "Not in a sharded topology"
      end
      options[:mongos] || 1
    end

    def num_data_bearing_nodes
      options[:data_bearing_nodes] || begin
        if options[:arbiter]
          2
        else
          3
        end
      end
    end

    def mongo_path(binary)
      if options[:bin_dir]
        File.join(options[:bin_dir], binary)
      else
        binary
      end
    end

    def server_version
      @server_version ||= Gem::Version.new(begin
        path = mongo_path('mongod')
        if path =~ /\s/
          raise "Path cannot contain spaces: #{path}"
        end

        output = `#{path} --version`
        if $?.exitstatus != 0
          raise "mongod --version exited with code #{$?.exitstatus}: #{output}"
        end

        unless output =~ /db version v(\d+\.\d+\.\d+)/
          raise "Output did not contain version: #{output}"
        end

        $1
      end)
    end

    def server_tls_args
      server_42 = server_version >= Gem::Version.new('4.2')
      @server_tls_args ||= if options[:tls_mode]
        if server_42
          opt_name = '--tlsMode'
          opt_value = options[:tls_mode]
        else
          opt_name = '--sslMode'
          opt_value = options[:tls_mode].sub('TLS','SSL')
        end
        args = [opt_name, opt_value]
        if options[:tls_certificate_key_file]
          if server_42
            opt_name = '--tlsCertificateKeyFile'
          else
            opt_name = '--sslPEMKeyFile'
          end
          args += [opt_name, options[:tls_certificate_key_file]]
        end
        if options[:tls_ca_file]
          if server_42
            opt_name = '--tlsCAFile'
          else
            opt_name = '--sslCAFile'
          end
          args += [opt_name, options[:tls_ca_file]]
        end
        args
      else
        []
      end.freeze
    end

    def client_tls_options
      if options[:tls_mode]
        {
          ssl: true,
          ssl_cert: options[:tls_certificate_key_file],
          ssl_key: options[:tls_certificate_key_file],
          ssl_ca_cert: options[:tls_ca_file],
        }
      else
        {}
      end.freeze
    end

    def spawn_standalone(dir, port, args)
      puts("Spawn mongod on port #{port}")
      FileUtils.mkdir_p(dir)
      cmd = [
        mongo_path('mongod'),
        dir.join('mongod.log').to_s,
        dir.join('mongod.pid').to_s,
        '--dbpath', dir.to_s,
        '--port', port.to_s,
      ] + args + server_tls_args + passthrough_args
      Helper.spawn_mongo(*cmd)
      record_start_command(dir, cmd)
    end

    def spawn_replica_set_node(dir, port, replica_set_name, args)
      puts("Spawn mongod on port #{port}")
      FileUtils.mkdir(dir)
      cmd = [
        mongo_path('mongod'),
        dir.join('mongod.log').to_s,
        dir.join('mongod.pid').to_s,
        '--dbpath', dir.to_s,
        '--port', port.to_s,
        '--replSet', replica_set_name,
      ] + args + server_tls_args + passthrough_args
      Helper.spawn_mongo(*cmd)
      record_start_command(dir, cmd)
    end

    def record_start_command(dir, cmd)
      dir = dir.to_s
      config[:settings] ||= {}
      config[:settings][dir] ||= {}
      config[:settings][dir][:start_cmd] = cmd
      config[:db_dirs] << dir unless config[:db_dirs].include?(dir)
    end

    def direct_client(address_str)
      client = Mongo::Client.new([address_str], client_tls_options.merge(
        connect: :direct))
      begin
        yield client
      ensure
        client.close
      end
    end
  end
end
