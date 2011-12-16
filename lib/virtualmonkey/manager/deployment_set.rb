require 'rubygems'
require 'rest_connection'
require 'pp'
require 'base64'

module VirtualMonkey
  module Manager
    class DeploymentSet
      attr_accessor :common_inputs
      attr_accessor :deployments

      # Returns an Array of Deployment objects whose nicknames start with @prefix
      def from_prefix_tag(prefix = @prefix)
        variations = Deployment.find_by_tags("info:prefix=#{prefix}")
        puts "loading #{variations.size} deployments matching your prefix"
        return variations
      end

      def self.from_name(prefix)
        variations = Deployment.find_by_tags("info:prefix=*").select { |d| d.nickname =~ Regexp.new("^#{Regexp.escape(prefix)}") }
        puts "loading #{variations.size} deployments matching your prefix"
        return variations
      end

      # Lists the nicknames of Array of Deployment objects whose nicknames start with prefix
      def self.list(prefix, verbose = false)
        deployments = Deployment.find_by_tags("info:prefix=#{prefix}")
        deployments = from_name(prefix) if deployments.empty?
        if verbose
          pp deployments.map { |d| { d.nickname => d.servers.map { |s| s.state } } }
        else
          pp deployments.map { |d| d.nickname }
        end
        puts "Found #{deployments.length} deployment#{deployments.one? ? nil : "s"} with " +
             "#{deployments.reduce(0) { |sum,d| sum + d.servers_no_reload.length } } servers."
      end

      # Lists the nicknames of Array of Deployment objects whose nicknames start with @prefix
      def list(verbose = false)
        if verbose
          pp @deployments.map { |d| { d.nickname => d.servers.map { |s| s.state } } }
        else
          pp @deployments.map { |d| d.nickname }
        end
        puts "Found #{@deployments.length} deployment#{@deployments.one? ? nil : "s"} with " +
             "#{@deployments.reduce(0) { |sum,d| sum + d.servers_no_reload.length } } servers."
      end

#      def initialize(prefix, server_templates = [], extra_images = [], allow_meta_monkey = false, single_deployment = false)
      def initialize(opts = {})
        raise ArgumentError.new("no :prefix option passed") unless opts[:prefix]
        @options = opts
        @clouds = []
        @single_deployment = @options[:one_deploy]
        @prefix = @options[:prefix]
        @deployments = from_prefix_tag
        @errors = []
        @server_templates = []
        @common_inputs = {}
        @variables_for_cloud = {}
        @ssh_keys, @security_groups, @datacenters, @instance_types = {}, {}, {}, {}
        #
        # mci.href => [ st.href, st.href ]
        #
        @multi_cloud_images = {}
        #
        # order => { st.href => mci }
        #
        @mci_order = {}
        if @options[:server_template_ids].empty? && @deployments.empty?
          raise "Need either populated deployments or passed in server_template ids"
        end

        # Get list of unique server_template ids
        if @options[:server_template_ids].empty?
          puts "loading server templates from all deployments"
          @deployments.each { |d|
            d.reload
            d.servers_no_reload.each { |s|
              @options[:server_template_ids] << s.server_template_href.split(/\//).last.to_i
            }
          }
          @options[:server_template_ids].uniq!
        end

        # Load ServerTemplate objects from names/ids
        @options[:server_template_ids].each do |st|
          if st =~ /[^0-9]/ #ServerTemplate Name was given
            sts_found << ServerTemplate.find_by(:nickname) { |n| n =~ /#{st}/ }
            raise "Found more than one ServerTemplate matching '#{st}'." unless sts_found.size == 1
            st = sts_found.first
          else #ServerTemplate ID was given
            st = ServerTemplate.find(st.to_i)
          end
          # Do not allow Servers using the VirtualMonkey ServerTemplate to be subject to monkey code
          unless @options[:allow_meta_monkey]
            raise "ABORTING: VirtualMonkey has been found in a deployment." if st.nickname =~ /virtual *monkey/i
          end
          @server_templates << st if @options[:allow_meta_monkey] or st.nickname !~ /virtual *monkey/i
        end
        raise "Error: To launch a single deployment a maximum of one server template is allowed " if ((@server_templates.length > 1) && @single_deployment)
      end

      def mci_list(options, st)
        if options[:use_mci] && !options[:use_mci].empty?
            mci = MultiCloudImage.new("href" => options[:use_mci].first)
            mci.reload
            mci.find_and_flatten_settings
            multi_cloud_images = [mci]
        elsif options[:only]
          multi_cloud_images = st.multi_cloud_images
          [options[:only]].flatten.compact.each do |filter|
            multi_cloud_images = multi_cloud_images.select { |mci| mci['name'] =~ /#{filter}/ }
          end
          wrapped_regexps = [options[:only]].flatten.compact.map { |filter| "/#{filter}/" }.join("&&")
          raise "No MCI on ServerTemplate '#{st.nickname}' matches regexps #{wrapped_regexps}" if multi_cloud_images.empty?
        else
          multi_cloud_images = st.multi_cloud_images
        end
        raise "No MCIs found on ServerTemplate '#{st.nickname}'!" if multi_cloud_images.empty?
        multi_cloud_images
      end

      def generate_variations(options = {}, create_command=nil)
        # Count the max number of images that we can select from (@image_count)
        # Get list of supported clouds (@clouds)
        dep_image_names = nil  # This variable holds the names of the images in the deployment
    #    @image_count = 0
        @server_templates.each do |st|
          multi_cloud_images = mci_list(options, st)
    #      @image_count = multi_cloud_images.size if multi_cloud_images.size > @image_count
          multi_cloud_images.each do |mci|
            @clouds += mci.supported_cloud_ids
            @multi_cloud_images[mci.href] ||= { :mci => mci, :st_ary => [] }
            next if @multi_cloud_images[mci.href][:st_ary].include?(st.href)
            @multi_cloud_images[mci.href][:st_ary] << st.href
          end
        end
        @clouds.flatten!
        @clouds.compact!
        @clouds.uniq!
        @clouds.map! { |m| m.to_s }
        @image_count = @multi_cloud_images.length
        raise "The selected MCIs don't support any clouds!" if @clouds.empty?
        #
        # Sort the MCI's so the same are created together
        #
        start = 0
        mci_map_1 = [] # Array of Hashes
        mci_map_2 = [] # Array of Arrays
        mci_map_3 = [] # Table
        @multi_cloud_images.each { |mci_href,hsh| mci_map_1 << hsh }
        mci_map_1.sort! { |a,b| b[:st_ary].length <=> a[:st_ary].length } # Descending order
        mci_map_2 = mci_map_1.map { |hsh| hsh[:st_ary] }
        mci_map_2.each_with_index { |st_ary,index|
          mci_map_3[index] ||= []
          @server_templates.each { |st|
            mci_map_3[index] << (st_ary.include?(st.href) ? mci_map_1[index][:mci] : nil)
          }
        }
        mci_map_3.transpose.each_with_index { |mci_ary,st_index|
          st_href = @server_templates[st_index].href
          mci_ary.each_with_index { |mci,order_index|
            if mci
              @mci_order[order_index] ||= {}
              @mci_order[order_index][st_href] = mci
            end
          }
        }

        # Calculate Deployments
        num_deployments = 0
        @image_count.times do |index|
          @clouds.each do |cloud|
            # Skip if the cloud hasn't been specified
            next if @variables_for_cloud[cloud] == nil

            # Check the candidate MCI or Skip if the selected MCI doesn't support the cloud
            dep_image_list = []
            mci_supports_cloud = nil
            @server_templates.each do |st|
              mci = nil
              alt_mci = nil
              if @mci_order[index][st.href] && @mci_order[index][st.href].supported_cloud_ids.include?(cloud.to_i)
                mci = @mci_order[index][st.href]
              else
                @image_count.times do |idx|
                  if @mci_order[idx][st.href] && @mci_order[idx][st.href].supported_cloud_ids.include?(cloud.to_i)
                    alt_mci = @mci_order[idx][st.href]
                    break
                  end
                end
              end
              # We don't want to create extra deployments if the mci for this "index" doesn't support the cloud
              if mci
                mci_supports_cloud = true if mci_supports_cloud.nil?
                mci_supports_cloud &&= mci && mci.supported_cloud_ids.include?(cloud.to_i)
                dep_image_list << URI.escape(mci.name.gsub(/ |\t/,'_'))
              elsif alt_mci.nil?
                mci_supports_cloud = false
              elsif alt_mci
                dep_image_list << URI.escape(alt_mci.name.gsub(/ |\t/,'_'))
              end
            end
            next unless mci_supports_cloud

            if @single_deployment && num_deployments < 1
              dep_tempname = "#{@prefix}-cloud_#{cloud}-#{rand(1000000)}-"
              dep_tempname = "#{@prefix}-cloud_multicloud-#{rand(1000000)}-" if @clouds.length > 1
              num_deployments += 1
              puts "#{num_deployments}. #{dep_tempname}ALL_IN_ONE"
            elsif !@single_deployment
              dep_tempname = "#{@prefix}-cloud_#{cloud}-#{rand(1000000)}-"
              num_deployments += 1
              puts "#{num_deployments}. #{dep_tempname + dep_image_list.uniq.join("_AND_")}"
            end
          end
        end
        if num_deployments < 1
          msg = "FATAL: No deployments to create. Please check your parameters carefully " +
                "and ensure that your ServerTemplates are set up correctly"
          error msg.word_wrap
        end

        if not options[:yes] and tty?
          unless ask("Are these the correct deployments that should be created?", lambda { |ans| ans =~ /^[yY]/ })
            error "Aborting on user input."
          end
        end

        dep_tempname = ""
        new_deploy = nil
        nick_name_holder = [] # this variable is used when we want to create a single deployment and we use it to name the deployment properly
        deployment_created = false # this variable is used to control creating a single deployment
        @image_count.times do |index|
          @clouds.each do |cloud|

            # Skip if the cloud hasn't been specified
            if @variables_for_cloud[cloud] == nil
              puts "Variables not found for cloud #{cloud}. Skipping..."
              next
            end

            # Check the candidate MCI or Skip if the selected MCI doesn't support the cloud
            mci_supports_cloud = nil
            @server_templates.each do |st|
              mci = nil
              alt_mci = nil
              if @mci_order[index][st.href] && @mci_order[index][st.href].supported_cloud_ids.include?(cloud.to_i)
                mci = @mci_order[index][st.href]
              else
                @image_count.times do |idx|
                  if @mci_order[idx][st.href] && @mci_order[idx][st.href].supported_cloud_ids.include?(cloud.to_i)
                    alt_mci = @mci_order[idx][st.href]
                    break
                  end
                end
              end
              # We don't want to create extra deployments if the mci for this "index" doesn't support the cloud
              if mci
                mci_supports_cloud = true if mci_supports_cloud.nil?
                mci_supports_cloud &&= mci && mci.supported_cloud_ids.include?(cloud.to_i)
              elsif alt_mci.nil?
                mci_supports_cloud = false
              end
            end
            unless mci_supports_cloud
              warn "Computed MCI Set ##{index} contains an MCI that doesn't support cloud #{cloud}. Skipping..."
              next
            end

            # Before Create Hooks?
            if options[:runner].respond_to?(:before_create)
              options[:runner].ancestors.select { |a| a.respond_to?(:before_create) }.each do |ancestor|
                if not ancestor.before_create.empty?
                  puts "Executing before_create hooks..."
                  runner_class = options[:runner]
                  runner_class.assert_integrity!
                  ancestor.before_create.each { |fn|
                    (fn.is_a?(Proc) ? runner_class.instance_eval(&fn) : runner_class.__send__(fn))
                  }
                  puts "Finished executing before_create hooks."
                end
              end
            else
              warn "#{options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
            end

            # Create Deployment for this MCI and cloud
            if @single_deployment && !deployment_created
              dep_tempname = "#{@prefix}-cloud_#{cloud}-#{rand(1000000)}-"
              dep_tempname = "#{@prefix}-cloud_multicloud-#{rand(1000000)}-" if @clouds.length > 1
              new_deploy = Deployment.create(:nickname => dep_tempname)
              new_deploy.set_info_tags("prefix" => @prefix)
              @deployments << new_deploy
              deployment_created = true
            elsif !@single_deployment
              dep_tempname = "#{@prefix}-cloud_#{cloud}-#{rand(1000000)}-"
              new_deploy = Deployment.create(:nickname => dep_tempname)
              new_deploy.set_info_tags("prefix" => @prefix)
              @deployments << new_deploy
            end

            tags = {"cloud" => (@single_deployment ? "multicloud" : cloud),
                    "troop" => options[:config_file],
                    "command" => Base64.encode64(VirtualMonkey::Command::last_command_line).chomp}
            new_deploy.set_info_tags(tags)

            dep_image_list = []
            @server_templates.each do |st|
              nick_name_holder << st.nickname.gsub(/ /,'_')  ## place the nickname into the array
              mci = nil
              #Select an MCI to use
              if @mci_order[index][st.href] && @mci_order[index][st.href].supported_cloud_ids.include?(cloud.to_i)
                mci = @mci_order[index][st.href]
              else
                @image_count.times do |idx|
                  if @mci_order[idx][st.href] && @mci_order[idx][st.href].supported_cloud_ids.include?(cloud.to_i)
                    mci = @mci_order[idx][st.href]
                    break
                  end
                end
              end
              dep_image_list << dep_image_names = URI.escape(mci.name.gsub(/ |\t/,'_'))
              if dep_image_names != mci.name.gsub(/ |\t/,'_')
                warn "MCI name has HREF-sensitive characters, this can cause trouble for reporting to S3"
              end

              use_this_image = mci.href

              # Load Cloud Variables from all_clouds.json
              load_vars_for_cloud(cloud)

              # Merge cloud_var parameters OVER common_inputs
              inputs = []
              @common_inputs.deep_merge(@variables_for_cloud[cloud]['parameters']).each do |key,val|
                inputs << { "name" => key, "value" => val }
              end


              #Set Server Creation Parameters
              serv_name = "#{@prefix[0...2]}-#{rand(1000000)}-#{st.nickname}-#{dep_image_names}" if @single_deployment
              serv_name = "#{@prefix[0...2]}-#{rand(1000000)}-#{st.nickname}" unless @single_deployment
              serv_name = "#{@prefix[0...2]}-#{rand(1000000)}" if cloud.to_s == "232"
              server_params = { "nickname" => serv_name,
                                "deployment_href" => new_deploy.href.dup,
                                "server_template_href" => st.href.dup,
                                "cloud_id" => cloud,
                                "inputs" => inputs,
                                "mci_href" => use_this_image
                                #"ec2_image_href" => image['image_href'],
                                #"instance_type" => image['aws_instance_type']
                              }

              # If overriding the multicloudimage need to specify the ec2 image href because you can't set an MCI that's not in the ServerTemplate
              if options[:use_mci] && !options[:use_mci].empty?
                server_params.reject! {|k,v| k == "mci_href"}
                use_this_image_setting = mci_list(options, st).first['multi_cloud_image_cloud_settings'].detect { |setting|
                  if setting.is_a?(MultiCloudImageCloudSettingInternal)
                    ret = (setting.cloud_id == cloud.to_i)
                  elsif setting.is_a?(McMultiCloudImageSetting)
                    ret = setting.cloud.include?("clouds/#{cloud}")
                  end
                  ret
                }
                if cloud.to_i < 10
                  server_params["ec2_image_href"] = use_this_image_setting["image_href"]
                  server_params["instance_type"] = use_this_image_setting["aws_instance_type"]
                else
                  server_params["image_href"] = use_this_image_setting.image
                  server_params["instance_type_href"] = use_this_image_setting.instance_type
                end
              end

              # Create Server
              if options[:force]
                begin
                  server = ServerInterface.new(cloud).create(server_params.deep_merge(@variables_for_cloud[cloud]))
                rescue Exception => e
                  msg = "GOT EXCEPTION: \"#{e.message}\""
                  warn "#\n# #{msg}\n#\n\n"
                  cmd = "ServerInterface.new(#{cloud}).create(#{server_params.deep_merge(@variables_for_cloud[cloud]).pretty_inspect})"
                  @errors << "#{msg} for #{cmd}"
                  next
                end
              else
                server = ServerInterface.new(cloud).create(server_params.deep_merge(@variables_for_cloud[cloud]))
              end

              # Set info tags on deployment
              tags = {}
              tags["server_#{server.rs_id}-servertemplate_id"] = "#{st.rs_id}"
              unless @single_deployment
                # MCI info isn't available from RightScale Server API
                if options[:use_mci] && !options[:use_mci].empty?
                  tags["mci_id"] = options[:use_mci].split(/\//).last
                else
                  tags["server_#{server.rs_id}-mci_id"] = use_this_image.split(/\//).last
                end
              end
              new_deploy.set_info_tags(tags)

              # AWS Cloud-specific Code XXX LEGACY XXX
              if cloud.to_i < 10
                # since the create call does not set the parameters, we need to set them separate
                server.set_inputs(@variables_for_cloud[cloud]['parameters'])

                # WHY WE NEED THIS? create maybe already does this
                # uses a special internal call for setting the MCI on the server
                sint = ServerInternal.new(:href => server.href)
                sint.set_multi_cloud_image(use_this_image) unless options[:use_mci] && !options[:use_mci].empty?

                # finally, set the spot price
                unless options[:no_spot]
                  server.reload
                  server.settings
                  if server.ec2_instance_type =~ /small/
                    server.max_spot_price = "0.085"
                  elsif server.ec2_instance_type =~ /large/
                    server.max_spot_price = "0.38"
                  end
                  server.pricing = "spot"
                  server.parameters = {}
                  server.save
                end
              end

              # Add image names to the deployment nickname
              new_deploy.nickname = dep_tempname + dep_image_list.uniq.join("_AND_")
              new_deploy.save

              # Set the inputs at the deployment level
              new_deploy.set_inputs(@common_inputs.deep_merge(@variables_for_cloud[cloud]['parameters']))
            end # @server_templates.each do |st|

            # After Create Hooks for multiple deployments?
            if options[:runner].respond_to?(:after_create)
              options[:runner].ancestors.select { |a| a.respond_to?(:after_create) }.each do |ancestor|
                if not ancestor.after_create.empty? and not @single_deployment
                  puts "Executing after_create hooks..."
                  runner = options[:runner].new(new_deploy.nickname)
                  ancestor.after_create.each { |fn|
                    (fn.is_a?(Proc) ? runner.instance_eval(&fn) : runner.__send__(fn))
                  }
                  puts "Finished executing after_create hooks."
                end
              end
            else
              warn "#{options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
            end
          end # @clouds.each do |cloud|
        end # @image_count.times do |index|

        if @single_deployment
          new_deploy.nickname = dep_tempname + nick_name_holder.uniq.join("_AND_") + "-ALL_IN_ONE"
          new_deploy.save

          # After Create Hooks for single deployment?
          if options[:runner].respond_to?(:after_create)
            options[:runner].ancestors.select { |a| a.respond_to?(:after_create) }.each do |ancestor|
              if not ancestor.after_create.empty?
                puts "Executing after_create hooks..."
                runner = options[:runner].new(new_deploy.nickname)
                ancestor.after_create.each { |fn|
                  (fn.is_a?(Proc) ? runner.instance_eval(&fn) : runner.__send__(fn))
                }
                puts "Finished executing after_create hooks."
              end
            end
          else
            warn "#{options[:runner]} doesn't extend VirtualMonkey::RunnerCore::CommandHooks"
          end
        end
        puts "\nError Summary:\n#{@errors.join("\n")}".apply_color(:red) if !@errors.empty?
        if @deployments.length > 0
          puts "\n#{@deployments.length} deployments now available:\n#{@deployments.pretty_inspect}".apply_color(:green)
        else
          error "\nNo deployments created!"
        end
      end

      def load_common_inputs(file)
        @common_inputs.deep_merge! JSON.parse(IO.read(file))
      end

      def load_clouds(cloud_ids)
        VirtualMonkey::Toolbox::populate_all_cloud_vars(cloud_ids, {:force => true})
        all_clouds = JSON::parse(IO.read(File.join(VirtualMonkey::GENERATED_CLOUD_VAR_DIR, "all_clouds.json")))
        proj = VirtualMonkey::Command::selected_project
        proj ||= VirtualMonkey::Manager::Collateral.get_project_from_constant(@options[:runner])
        proj ||= VirtualMonkey::Manager::Collateral.get_project_from_file(@options[:config_file])
        VirtualMonkey::Command::selected_project ||= proj
        VirtualMonkey::Command::selected_project.cloud_variables.each do |cloud_var_file|
          all_clouds.deep_merge! JSON::parse(IO.read(cloud_var_file))
        end
        cloud_ids.each { |id| @variables_for_cloud.deep_merge!(id.to_s => all_clouds[id.to_s]) }
      end

      def update_inputs
        @deployments.each do |d|
          c_inputs = @common_inputs.dup

          # Set inputs at the Deployment level
          # If deployment has the string "-cloud_#-", then collect inputs from cloud_vars
          if d.cloud_id and load_vars_for_cloud(d.cloud_id)
            d.set_inputs(c_inputs.deep_merge(@variables_for_cloud[d.cloud_id.to_s]['parameters']))
          else
            d.set_inputs(c_inputs)
          end

          # Set inputs at the Server level
          d.servers.each { |s|
            cid = VirtualMonkey::Toolbox::determine_cloud_id(s).to_s
            cv_inputs = (load_vars_for_cloud(cid) ? @variables_for_cloud[cid]['parameters'] : {})
            s.set_inputs(c_inputs.deep_merge(cv_inputs))
          }
        end
      end

      def load_vars_for_cloud(cloud)
        cloud = cloud.to_s
        return nil unless @variables_for_cloud[cloud]
        unless @ssh_keys[cloud] and @ssh_keys[cloud] != {}
          VirtualMonkey::Toolbox::generate_ssh_keys(cloud)
          @ssh_keys = JSON::parse(IO.read(File.join(VirtualMonkey::GENERATED_CLOUD_VAR_DIR, "ssh_keys.json")))
        end
        unless @security_groups[cloud] and @security_groups[cloud] != {}
          VirtualMonkey::Toolbox::populate_security_groups(cloud)
          @security_groups = JSON::parse(IO.read(File.join(VirtualMonkey::GENERATED_CLOUD_VAR_DIR, "security_groups.json")))
        end
        unless @instance_types[cloud] and @instance_types[cloud] != {}
          VirtualMonkey::Toolbox::populate_datacenters(cloud)
          @instance_types = JSON::parse(IO.read(File.join(VirtualMonkey::GENERATED_CLOUD_VAR_DIR, "instance_types.json")))
        end
        unless @datacenters[cloud] and @datacenters[cloud] != {}
          VirtualMonkey::Toolbox::populate_datacenters(cloud)
          @datacenters = JSON::parse(IO.read(File.join(VirtualMonkey::GENERATED_CLOUD_VAR_DIR, "datacenters.json")))
        end
        generated_variables = {}
        generated_variables.deep_merge!(@ssh_keys[cloud])
        generated_variables.deep_merge!(@security_groups[cloud])
        generated_variables.deep_merge!(@instance_types[cloud])
        generated_variables.deep_merge!(@datacenters[cloud])
        generated_variables.deep_merge!(@variables_for_cloud[cloud]) # Higher Priority than generated content
        @variables_for_cloud[cloud].deep_merge!(generated_variables)
        true
      end

      def destroy_all
        @deployments.each { |v|
          v.servers_no_reload.each { |s|
            s.wait_for_state("stopped")
          }
          v.destroy
        }
        @deployments = []
      end

      def set_server_params
        @deployments.each do |d|
          d.servers.each { |s|
            cid = VirtualMonkey::Toolbox::determine_cloud_id(s).to_s
            s.update(@variables_for_cloud[cid]) if load_vars_for_cloud(cid)
          }
        end
      end

    end
  end
end
