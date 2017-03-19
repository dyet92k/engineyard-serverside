require 'thor'
require 'pathname'
require 'engineyard-serverside/about'
require 'engineyard-serverside/deploy'
require 'engineyard-serverside/propagator'
require 'engineyard-serverside/shell'
require 'engineyard-serverside/server_hash_extractor'
require 'engineyard-serverside/servers'
require 'engineyard-serverside/cli_helpers'

module EY
  module Serverside
    class CLI < Thor

      extend CLIHelpers

      method_option :migrate,         :type     => :string,
                                      :desc     => "Run migrations with this deploy",
                                      :aliases  => ["-m"]

      method_option :branch,          :type     => :string,
                                      :desc     => "Git ref to deploy, defaults to master. May be a branch, a tag, or a SHA",
                                      :aliases  => %w[-b --ref --tag]

      method_option :repo,            :type     => :string,
                                      :desc     => "Remote repo to deploy",
                                      :aliases  => ["-r"]


      # Archive source strategy
      method_option :archive,        :type     => :string,
                                     :desc     => "Remote URI for archive to download and unzip"

      # Git source strategy
      method_option :git,            :type     => :string,
                                     :desc     => "Remote git repo to deploy"

      method_option :clean,          :type     => :boolean,
                                     :desc     => "Run deploy without relying on existing files"


      account_app_env_options
      config_option
      framework_env_option
      instances_options
      stack_option
      verbose_option

      desc "deploy", "Deploy code to /data/<app>"
      def deploy(default_task=:deploy)
        init_and_propagate(options, default_task.to_s) do |servers, config, shell|
          EY::Serverside::Deploy.new(servers, config, shell).send(default_task)
        end
      end

      account_app_env_options
      config_option
      instances_options
      verbose_option
      desc "enable_maintenance", "Enable maintenance page (disables web access)"
      def enable_maintenance
        init_and_propagate(options, 'enable_maintenance') do |servers, config, shell|
          EY::Serverside::Maintenance.new(servers, config, shell).manually_enable
        end
      end

      account_app_env_options
      config_option
      instances_options
      verbose_option
      desc "maintenance_status", "Maintenance status"
      def maintenance_status
        init(options, "maintenance-status") do |servers, config, shell|
          EY::Serverside::Maintenance.new(servers, config, shell).status
        end
      end

      account_app_env_options
      config_option
      instances_options
      verbose_option
      desc "disable_maintenance", "Disable maintenance page (enables web access)"
      def disable_maintenance
        init_and_propagate(options, 'disable_maintenance') do |servers, config, shell|
          EY::Serverside::Maintenance.new(servers, config, shell).manually_disable
        end
      end

      method_option :release_path,  :type     => :string,
                                    :desc     => "Value for #release_path in hooks (mostly for internal coordination)",
                                    :aliases  => ["-r"]

      method_option :current_roles, :type     => :array,
                                    :desc     => "Value for #current_roles in hooks"

      method_option :current_name,  :type     => :string,
                                    :desc     => "Value for #current_name in hooks"
      account_app_env_options
      config_option
      framework_env_option
      verbose_option
      desc "hook [NAME]", "Run a particular deploy hook"
      def hook(hook_name)
        init(options, "hook-#{hook_name}") do |servers, config, shell|
          EY::Serverside::DeployHook.new(config, shell, hook_name).call
        end
      end

      method_option :ignore_existing, :type     => :boolean,
                                      :desc     => "When syncing /data/app directory, don't overwrite destination files"
      account_app_env_options
      config_option
      framework_env_option
      instances_options
      stack_option
      verbose_option
      desc "integrate", "Integrate other instances into this cluster"
      def integrate
        app_dir = Pathname.new "/data/#{options[:app]}"
        current_app_dir = app_dir.join("current")

        # so that we deploy to the same place there that we have here
        integrate_options = options.dup
        integrate_options[:release_path] = current_app_dir.realpath.to_s

        # we have to deploy the same SHA there as here
        integrate_options[:branch] = current_app_dir.join('REVISION').read.strip

        # always rebundle gems on integrate to make sure the instance comes up correctly.
        integrate_options[:clean] = true

        logname = "integrate-#{options[:instances].join('-')}".gsub(/[^-.\w]/,'')

        init_and_propagate(integrate_options, logname) do |servers, config, shell|

          # We have to rsync the entire app dir, so we need all the permissions to be correct!
          chown_command = %|find #{app_dir} \\( -not -user #{config.user} -or -not -group #{config.group} \\) -exec chown -h #{config.user}:#{config.group} "{}" +|
          shell.logged_system("sudo sh -l -c '#{chown_command}'", servers.detect {|s| s.local?})

          servers.run_for_each! do |server|
            chown = server.command_on_server('sudo sh -l -c', chown_command)
            sync  = server.sync_directory_command(app_dir, options[:ignore_existing])
            clean = server.command_on_server('sh -l -c', "rm -rf #{current_app_dir}")
            "(#{chown}) && (#{sync}) && (#{clean})"
          end

          # deploy local-ref to other instances into /data/$app/local-current
          EY::Serverside::Deploy.new(servers, config, shell).cached_deploy
        end
      end

      account_app_env_options
      instances_options
      stack_option
      verbose_option
      desc "restart", "Restart app servers, conditionally enabling maintenance page"
      def restart
        options = self.options.dup
        options[:release_path] = Pathname.new("/data/#{options[:app]}/current").realpath.to_s

        init_and_propagate(options, 'restart') do |servers, config, shell|
          EY::Serverside::Deploy.new(servers, config, shell).restart_with_maintenance_page
        end
      end

      private

      def init_and_propagate(*args)
        init(*args) do |servers, config, shell|
          Propagator.propagate(servers, shell)
          yield servers, config, shell
        end
      end

      def init(options, action)
        config = EY::Serverside::Deploy::Configuration.new(options)
        shell  = EY::Serverside::Shell.new(
          :verbose  => config.verbose,
          :log_path => File.join(ENV['HOME'], "#{config.app}-#{action}.log")
        )
        shell.debug "Initializing #{About.name_with_version}."
        servers = load_servers(config, shell)
        begin
          yield servers, config, shell
        rescue EY::Serverside::RemoteFailure => e
          shell.fatal e.message
          raise
        rescue Exception => e
          shell.fatal "#{e.backtrace[0]}: #{e.message} (#{e.class})"
          raise
        end
      end

      def load_servers(config, shell)
        #EY::Serverside::Servers.from_hashes(assemble_instance_hashes(config), shell)
        EY::Serverside::Servers.from_hashes(
          ServerHashExtractor.hashes(options, config),
          shell
        )
      end

      def assemble_instance_hashes(config)
        if options[:instances]
          options[:instances].collect { |hostname|
            { :hostname => hostname,
              :roles => options[:instance_roles][hostname].to_s.split(','),
              :name => options[:instance_names][hostname],
              :user => config.user,
            }
          }
        else
          []
        end
      end

    end
  end
end
