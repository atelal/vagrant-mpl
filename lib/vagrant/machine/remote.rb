module Vagrant
  class Machine
    # This module enables the Machine for server mode
    module Remote

      # Add an attribute reader for the client
      # when applied to the Machine class
      def self.prepended(klass)
        klass.class_eval do
          attr_reader :client
        end
      end

      # Initialize a new machine.
      #
      # @param [String] name Name of the virtual machine.
      # @param [Class] provider The provider backing this machine. This is
      #   currently expected to be a V1 `provider` plugin.
      # @param [Object] provider_config The provider-specific configuration for
      #   this machine.
      # @param [Hash] provider_options The provider-specific options from the
      #   plugin definition.
      # @param [Object] config The configuration for this machine.
      # @param [Pathname] data_dir The directory where machine-specific data
      #   can be stored. This directory is ensured to exist.
      # @param [Box] box The box that is backing this virtual machine.
      # @param [Environment] env The environment that this machine is a
      #   part of.
      def initialize(name, provider_name, provider_cls, provider_config, provider_options, config, data_dir, box, env, vagrantfile, base=false, client: nil)
        @logger = Log4r::Logger.new("vagrant::machine")
        if !env.nil? && client.nil?
          @env = env
          @client = env.get_target(name)
        else
          @client = client
          @env = client.environment
        end

        if @client.nil?
          raise ArgumentError,
            "Remote client is required for `#{self.class.name}'"
        end

        @name = @client.name
        @ui = Vagrant::UI::Prefixed.new(@env.ui, @name)
        # TODO: get vagrantfile from go
        @vagrantfile = @env.vagrantfile
        @provider_name = @client.provider_name
        provider_cls = Array(
          Vagrant.plugin("2").remote_manager.providers[@provider_name.to_sym]
        ).first
        @provider = provider_cls.new(self, {client: @client.provider})
        # TODO: get machine config info from go
        mc = @vagrantfile.machine_config(@name.to_sym, @provider_name.to_sym, nil)
        @config = mc[:config]
        @provider_options = mc[:provider_options]
        @provider_config = @config.vm.get_provider_config(@provider_name.to_sym)

        @data_dir        = @client.data_dir
        @name            = name
        @ui_mutex        = Mutex.new
        @state_mutex     = Mutex.new
        # TODO: pass in trigger config (@config.trigger)
        @triggers        = Vagrant::Plugin::V2::Trigger.new(@env, nil, self, @ui)

        # If the ID is the special not created ID, then set our ID to
        # nil so that we destroy all our data.
        # if state.id == MachineState::NOT_CREATED_ID
        #   self.id = nil
        # end

        # Output a bunch of information about this machine in
        # machine-readable format in case someone is listening.
        @ui.machine("metadata", "provider", provider_name)
      end

      # @return [Box]
      def box
        box = client.box
        # If the version isn't set, then the box has not being tracked
        # by Vagrant.
        if box.version.empty?
          box = nil
        end
        return box
      end

      # TODO
      # def config
      #   raise NotImplementedError, "TODO"
      # end

      def communicate
        if !@communicate
          @communicate = Vagrant::Plugin::Remote::Communicator.new(self)
        end
        @communicate
      end

      def data_dir
        client.data_dir
      end

      def guest
        if !@guest
          @guest = Guest.new(self, nil, nil)
        end
        @guest
      end

      def id
        result = client.id
        result.to_s.empty? ? nil : result
      end

      def id=(value)
        @logger.info("New machine ID: #{value.inspect}")
        client.set_id(value.to_s)
        # Store the ID locally
        @id = value.nil? ? nil : value.to_s
        # Notify the provider that the ID changed in case it needs to do
        # any accounting from it. This is only used for local Ruby providers
        @provider.machine_id_changed
      end

      def inspect
        "<Vagrant::Machine:resource_id=#{client.resource_id}>"
      end

      def index_uuid
        id
      end

      def name
        client.name.to_sym
      end

      def provider
        @provider
      end

      def provider_name
        client.provider_name.to_sym
      end

      def provider_options
        @provider_options
      end

      def recover_machine(*_)
        nil
      end

      def reload
        id
      end

      def state
        client.machine_state
      end

      def ssh_info
        # First, ask the provider for their information. If the provider
        # returns nil, then the machine is simply not ready for SSH, and
        # we return nil as well.
        info = @provider.ssh_info
        return nil if info.nil?

        # Delete out the nil entries.
        info.dup.each do |key, value|
          info.delete(key) if value.nil?
        end

        # We set the defaults
        info[:host] ||= @config.ssh.default.host
        info[:port] ||= @config.ssh.default.port
        info[:private_key_path] ||= @config.ssh.default.private_key_path
        info[:keys_only] ||= @config.ssh.default.keys_only
        info[:verify_host_key] ||= @config.ssh.default.verify_host_key
        info[:username] ||= @config.ssh.default.username
        info[:remote_user] ||= @config.ssh.default.remote_user
        info[:compression] ||= @config.ssh.default.compression
        info[:dsa_authentication] ||= @config.ssh.default.dsa_authentication
        info[:extra_args] ||= @config.ssh.default.extra_args
        info[:config] ||= @config.ssh.default.config

        # We set overrides if they are set. These take precedence over
        # provider-returned data.
        info[:host] = @config.ssh.host if @config.ssh.host
        info[:port] = @config.ssh.port if @config.ssh.port
        info[:keys_only] = @config.ssh.keys_only
        info[:verify_host_key] = @config.ssh.verify_host_key
        info[:compression] = @config.ssh.compression
        info[:dsa_authentication] = @config.ssh.dsa_authentication
        info[:username] = @config.ssh.username if @config.ssh.username
        info[:password] = @config.ssh.password if @config.ssh.password
        info[:remote_user] = @config.ssh.remote_user if @config.ssh.remote_user
        info[:extra_args] = @config.ssh.extra_args if @config.ssh.extra_args
        info[:config] = @config.ssh.config if @config.ssh.config

        # We also set some fields that are purely controlled by Vagrant
        info[:forward_agent] = @config.ssh.forward_agent
        info[:forward_x11] = @config.ssh.forward_x11
        info[:forward_env] = @config.ssh.forward_env
        info[:connect_timeout] = @config.ssh.connect_timeout

        info[:ssh_command] = @config.ssh.ssh_command if @config.ssh.ssh_command

        # Add in provided proxy command config
        info[:proxy_command] = @config.ssh.proxy_command if @config.ssh.proxy_command

        # Set the private key path. If a specific private key is given in
        # the Vagrantfile we set that. Otherwise, we use the default (insecure)
        # private key, but only if the provider didn't give us one.
        if !info[:private_key_path] && !info[:password]
          if @config.ssh.private_key_path
            info[:private_key_path] = @config.ssh.private_key_path
          elsif info[:keys_only]
            info[:private_key_path] = @env.default_private_key_path
          end
        end

        # If we have a private key in our data dir, then use that
        if @data_dir && !@config.ssh.private_key_path
          data_private_key = @data_dir.join("private_key")
          if data_private_key.file?
            info[:private_key_path] = [data_private_key.to_s]
          end
        end

        # Setup the keys
        info[:private_key_path] ||= []
        info[:private_key_path] = Array(info[:private_key_path])

        # Expand the private key path relative to the root path
        info[:private_key_path].map! do |path|
          File.expand_path(path, @env.root_path)
        end

        # Check that the private key permissions are valid
        info[:private_key_path].each do |path|
          key_path = Pathname.new(path)
          if key_path.exist?
            Vagrant::Util::SSH.check_key_permissions(key_path)
          end
        end

        # Return the final compiled SSH info data
        info
      end

      def uid
        client.uid
      end

      def with_ui(ui)
        @ui_mutex.synchronize do
          begin
            old_ui = @ui
            @ui    = ui
            yield
          ensure
            @ui = old_ui
          end
        end
      end

      def check_cwd
        desired_encoding = @env.root_path.to_s.encoding
        vagrant_cwd_filepath = @data_dir.join('vagrant_cwd')
        vagrant_cwd = if File.exist?(vagrant_cwd_filepath)
                        File.read(vagrant_cwd_filepath,
                          external_encoding: desired_encoding
                        ).chomp
                      end

        if !File.identical?(vagrant_cwd.to_s, @env.root_path.to_s)
          if vagrant_cwd
            ui.warn(I18n.t(
              'vagrant.moved_cwd',
              old_wd:     "#{vagrant_cwd}",
              current_wd: "#{@env.root_path.to_s}"))
          end
          File.write(vagrant_cwd_filepath, @env.root_path.to_s,
            external_encoding: desired_encoding
          )
        end
      end

      def synced_folders
        folders = Vagrant::Plugin::V2::SyncedFolder::Collection.new
        synced_folder_clients = client.synced_folders
        synced_folder_clients.each do |f|
          next if f[:folder][:disabled]
          if f[:folder][:type].to_s != ""
            impl = f[:folder][:type].to_sym
          else
            impl = :virtualbox
          end
          sf = Vagrant::Plugin::Remote::SyncedFolder.new(client: f[:plugin])
          # Set plugin, guestpath and hostpath from synced folder info
          new_folder = {f[:folder][:destination] => f[:folder].merge({
            plugin: sf,
            guestpath: f[:folder][:destination],
            hostpath: f[:folder][:source],
          })}
          if folders[impl]
            folders[impl].merge!(new_folder)
          else
            folders[impl] = new_folder
          end
        end
        folders
      end

      def to_proto
        client.proto
      end
    end
  end
end
