require 'engineyard-cloud-client/models'
require 'engineyard-cloud-client/errors'

module EY
  class CloudClient
    class Environment < ApiStruct.new(:id, :name, :framework_env, :instances_count,
                                      :username, :app_server_stack_name, :deployment_configurations,
                                      :load_balancer_ip_address)

      attr_accessor :ignore_bad_master, :apps, :account, :instances, :app_master

      def initialize(api, attrs)
        super

        @apps = App.from_array(api, attrs['apps']) if attrs['apps']
        @account = Account.from_hash(api, attrs['account']) if attrs['account']
        @instances = Instance.from_array(api, attrs['instances'], 'environment' => self) if attrs['instances']
        @app_master = Instance.from_hash(api, attrs['app_master'].merge('environment' => self)) if attrs['app_master']
      end

      # Return list of all Environments linked to all current user's accounts
      def self.all(api)
        self.from_array(api, api.request('/environments')["environments"])
      end

      # Return a constrained list of environments given a set of constraints like:
      #
      # * app_name
      # * account_name
      # * environment_name
      # * remotes:  An array of git remote URIs
      #
      def self.resolve(api, constraints)
        clean_constraints = constraints.reject { |k,v| v.nil? }
        params = {'constraints' => clean_constraints}
        response = api.request("/environments/resolve", :method => :get, :params => params)
        matches = from_array(api, response['environments'])
        problems = no_environment_error(constraints) if matches.size.zero?
        ResolverResult.new(matches, problems, nil)
      end

      # DELETE ME
      def self.no_environment_error(constraints)
        if constraints[:environment_name]
          "No environment found matching '#{constraints[:environment_name]}'\nYou can create one at #{EY::CloudClient.endpoint}"
        else
          return <<-ERROR
No application configured for any of the following remotes:
\t#{constraints[:remotes].join("\n\t")}
You can add this application at #{EY::CloudClient.endpoint}.
          ERROR
        end
      end

      # Usage
      # Environment.create(api, {
      #      app: app,                            # requires: app.id
      #      name: 'myapp_production',
      #      region: 'us-west-1',                 # default: us-east-1
      #      app_server_stack_name: 'nginx_thin', # default: nginx_passenger3
      #      framework_env: 'staging'             # default: production
      #      cluster_configuration: {
      #        configuration: 'single'            # default: single, cluster, custom
      #      }
      # })
      #
      # NOTE: Syntax above is for Ruby 1.9. In Ruby 1.8, keys must all be strings.
      #
      # TODO - allow any attribute to be sent through that the API might allow; e.g. region, ruby_version, stack_label
      def self.create(api, attrs={})
        app    = attrs.delete("app")
        cluster_configuration = attrs.delete('cluster_configuration')
        raise EY::CloudClient::AttributeRequiredError.new("app", EY::CloudClient::App) unless app
        raise EY::CloudClient::AttributeRequiredError.new("name") unless attrs["name"]

        params = {"environment" => attrs.dup}
        unpack_cluster_configuration(params, cluster_configuration)
        response = api.request("/apps/#{app.id}/environments", :method => :post, :params => params)
        self.from_hash(api, response['environment'])
      end

      def account_name
        account && account.name
      end

      def ssh_username=(user)
        self.username = user
      end

      def logs
        Log.from_array(api, api.request("/environments/#{id}/logs", :method => :get)["logs"])
      end

      def app_master!
        master = app_master
        if master.nil?
          raise NoAppMasterError.new(name)
        elsif !ignore_bad_master && master.status != "running"
          raise BadAppMasterStatusError.new(master.status)
        end
        master
      end

      alias bridge! app_master!

      def rebuild
        api.request("/environments/#{id}/update_instances", :method => :put)
      end

      def run_custom_recipes
        api.request("/environments/#{id}/run_custom_recipes", :method => :put)
      end

      def download_recipes
        if File.exist?('cookbooks')
          raise EY::CloudClient::Error, "Could not download, cookbooks already exists"
        end

        require 'tempfile'
        tmp = Tempfile.new("recipes")
        tmp.write(api.request("/environments/#{id}/recipes"))
        tmp.flush
        tmp.close

        cmd = "tar xzf '#{tmp.path}' cookbooks"

        unless system(cmd)
          raise EY::CloudClient::Error, "Could not unarchive recipes.\nCommand `#{cmd}` exited with an error."
        end
      end

      def upload_recipes_at_path(recipes_path)
        recipes_path = Pathname.new(recipes_path)
        if recipes_path.exist?
          upload_recipes recipes_path.open('rb')
        else
          raise EY::CloudClient::Error, "Recipes file not found: #{recipes_path}"
        end
      end

      def tar_and_upload_recipes_in_cookbooks_dir
        require 'tempfile'
        unless File.exist?("cookbooks")
          raise EY::CloudClient::Error, "Could not find chef recipes. Please run from the root of your recipes repo."
        end

        recipes_file = Tempfile.new("recipes")
        cmd = "tar czf '#{recipes_file.path}' cookbooks/"

        unless system(cmd)
          raise EY::CloudClient::Error, "Could not archive recipes.\nCommand `#{cmd}` exited with an error."
        end

        upload_recipes(recipes_file)
      end

      def upload_recipes(file_to_upload)
        api.request("/environments/#{id}/recipes", {
          :method => :post,
          :params => {:file => file_to_upload}
        })
      end

      def shorten_name_for(app)
        name.gsub(/^#{Regexp.quote(app.name)}_/, '')
      end

      def launch
        Launchy.open(app_master!.hostname_url)
      end

      private

      def no_migrate?(deploy_options)
        deploy_options.key?('migrate') && deploy_options['migrate'] == false
      end

      # attrs["cluster_configuration"]["cluster"] can be 'single', 'cluster', or 'custom'
      # attrs["cluster_configuration"]["ip"] can be
      #   * 'host' (amazon public hostname)
      #   * 'new' (Elastic IP assigned, default)
      #   * or an IP id
      # if 'custom' cluster, then...
      def self.unpack_cluster_configuration(attrs, configuration)
        if configuration
          attrs["cluster_configuration"] = configuration
          attrs["cluster_configuration"]["configuration"] ||= 'single'
          attrs["cluster_configuration"]["ip_id"] = configuration.delete("ip") || 'new' # amazon public hostname; alternate is 'new' for Elastic IP

          # if cluster_type == 'custom'
          #   attrs['cluster_configuration'][app_server_count] = options[:app_instances] || 2
          #   attrs['cluster_configuration'][db_slave_count]   = options[:db_instances] || 0
          #   attrs['cluster_configuration'][instance_size]    = options[:app_size] if options[:app_size]
          #   attrs['cluster_configuration'][db_instance_size] = options[:db_size] if options[:db_size]
          # end
          # at
        end
      end
    end
  end
end