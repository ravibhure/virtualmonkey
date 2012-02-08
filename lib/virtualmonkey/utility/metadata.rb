module VirtualMonkey
  module Metadata
    extend self

    ################################
    # Metadata Reporting/Discovery #
    ################################

    def describe_metadata_fields(type=nil)
       fields = {
        "user" => ["email", "name"],
        "mci" => ["name", "href", "os", "os_version", "arch", "rightlink", "rev", "id"],
        "servertemplate" => ["name", "href", "id", "rev"],
        "cloud" => ["name", "id"],
        "feature" => [],
        "instancetype" => ["name", "href"],
        "datacenter" => ["name", "href"],
        "troop" => [],
        "report_page" => [],
        "logs" => [],
        "tag" => [],
        "started_at" => [],
        "command" => ["create", "run"],
        "status" => [],
      }
      (type ? fields[type] : fields.keys)
    end

    def get_metadata(opts={})
      data = {}
      describe_metadata_fields.each { |field|
        m_name = "get_#{field}_metadata"
        data.deep_merge!(send(m_name, opts)) if respond_to?(m_name)
      }
      data
    end

    def get_report_metadata(deployment, feature, options, started_at)
      data = {}

      # Filterable Data
      data.deep_merge!(get_metadata("deployment" => deployment))
      data["troop"] = [options[:config_file]]
      data["tags"] = [options[:report_tags]].flatten.compact

      # Extra Report Data
      data["status"] = "running" # status => "pending|running|failed|passed|blocked" (or, manually, "willnotdo")
      data["report_page"] = nil # nil until first upload
      data["started_at"] = started_at.utc.strftime("%Y/%m/%d %H:%M:%S +0000")
      if feature
        data["feature"] = [feature] # TODO: Gather runner info and runner option info?
      end
      command_create = deployment.get_info_tags["self"]["command"]
      data["command_create"] = Base64.decode64(command_create) if command_create
      if options[:command_run]
        data["command_run"] = options[:command_run]
      else
        data["command_run"] = VirtualMonkey::Command::last_command_line
      end

      # Unique JobID
      data["uid"] = started_at.strftime("%Y%m%d%H%M%S#{deployment.rs_id}")

      data
    end

    #
    # User Data
    #

    def get_user_metadata(opts)
      data = {}
      describe_metadata_fields("user").each { |f| data["user_#{f}"] = `git config user.#{f}`.chomp }
      data
    end

    #
    # MCI Data
    #

    def determine_rightlink_version(mci, regex)
      if (mci.name =~ /v([0-9]+(?:\.[0-9]+){2})/)
        return $1
      end
      mci.find_and_flatten_settings
      settings_ary = mci.multi_cloud_image_cloud_settings
      settings_ary.each { |setting|
        if setting.is_a?(MultiCloudImageCloudSettingInternal)
          if version = (setting.image_name =~ regex && $3)
            return version
          end
        elsif setting.is_a?(McMultiCloudImageSetting)
          if image = McImage.find(setting.image)
            if version = (image.name =~ regex && $3)
              return version
            end
          end
        end
      }
    end

    def get_mci_metadata(opts)
      data = {}
      describe_metadata_fields("mci").each { |f| data["mci_#{f}"] = [] }

      # Define extract_data proc
      extract_data = proc do |mci|
        data["mci_name"] |= [mci.name]
        data["mci_href"] |= [mci.href]
        data["mci_rev"] |= [mci.version]
        data["mci_id"] |= [mci.rs_id]

        # Extra Info
        hypervisors = "KVM|Vmware|XenServer"
        oses = "CentOS|RHEL|Ubuntu|Windows|Debian|Fedora|FreeBSD|SLES"
        if mci.name =~ /RightImage/i
          regex = nil
          if mci.name =~ /CentOS/i
            data["mci_os"] |= ["CentOS"]
            #        CentOS  Version   Arch    RightLink   Hypervisor (optional)
            regex = /CentOS_([.0-9]*)_([^_]*)_v([.0-9]*)(?:[- ]*(#{hypervisors}))?/i
          elsif mci.name =~ /RHEL/i
            data["mci_os"] |= ["RHEL"]
            #        RHEL  Version   Arch    RightLink   Hypervisor (optional)
            regex = /RHEL_([.0-9]*)_([^_]*)_v([.0-9]*)(?:[- ]*(#{hypervisors}))?/i
          elsif mci.name =~ /Ubuntu/i
            data["mci_os"] |= ["Ubuntu"]
            #        Ubuntu  Version Nickname    Arch    RightLink   Hypervisor (optional)
            regex = /Ubuntu_([.0-9]*)[_a-zA-Z]*_([^_]*)_v([.0-9]*)(?:[- ]*(#{hypervisors}))?/i
          elsif mci.name =~ /Windows/i
            data["mci_os"] |= ["Windows"]
            #        Windows  Version   ServicePack  Arch    App    RightLink   Hypervisor (optional)
            regex = /Windows_([0-9A-Za-z]*[_SP0-9]*)_([^_]*)[\w.]*_v([.0-9]*)(?:[- ]*(#{hypervisors}))?/i
          end
          if regex
            data["mci_os_version"] |= [(mci.name =~ regex && $1 || nil)].compact
            data["mci_arch"] |= [(mci.name =~ regex && $2 || nil)].compact
            unless opts[:skip_rightlink_version_check]
              data["mci_rightlink"] |= [(determine_rightlink_version(mci, regex) || nil)].compact
            end
            #data["mci_hypervisor"] |= [(mci.name =~ regex && $4 || nil)].compact
          end
        else
          data["mci_os"] |= [(mci.name =~ /(#{oses})/i && $1 || nil)].compact
          data["mci_os_version"] |= []
          data["mci_arch"] |= [(mci.name =~ /(i[3-6]86|x64|x86_64)/ && $1 || nil)].compact
          data["mci_rightlink"] |= [(mci.name =~ /v([0-9]+(?:\.[0-9]+){2})/ && $1 || nil)].compact
          #data["mci_hypervisor"] |= [(mci.name =~ /(#{hypervisors})/i && $1 || nil)].compact
        end
      end

      # Switch on possible inputs
      if RightScale::Api::Base === opts["mci"]
        extract_data[opts["mci"]]
      elsif RightScale::Api::Base === opts["servertemplate"]
        opts["servertemplate"].multi_cloud_images.each { |mci| extract_data[mci] }
      elsif RightScale::Api::Base === opts["deployment"]
        opts["deployment"].get_info_tags["self"].each { |key,val|
          extract_data[MultiCloudImage.find(val.to_i)] if key =~ /mci_id/
        }
      else
        raise ArgumentError.new("#{this_method} requires a 'deployment', 'mci', or 'servertemplate'")
      end
      data
    end

    #
    # ServerTemplate Data
    #

    def get_servertemplate_metadata(opts)
      data = {}
      describe_metadata_fields("servertemplate").each { |f| data["servertemplate_#{f}"] = [] }

      # Define extract_data proc
      extract_data = proc do |st|
        data["servertemplate_name"] |= [st.nickname]
        data["servertemplate_href"] |= [st.href]
        data["servertemplate_rev"] |= [st.version]
        data["servertemplate_id"] |= [st.rs_id]
      end

      # Switch on possible inputs
      if RightScale::Api::Base === opts["servertemplate"]
        extract_data[opts["servertemplate"]]
      elsif RightScale::Api::Base === opts["server"]
        opts["server"].settings unless opts["server"].server_template_href
        st = ServerTemplate.find(opts["server"].server_template_href.split("/").last.to_i)
        extract_data[st]
      elsif RightScale::Api::Base === opts["deployment"]
        opts["deployment"].servers.each do |s|
          data.deep_merge!(send(this_method, opts.merge({"server" => s})))
        end
      else
        raise ArgumentError.new("#{this_method} requires a 'deployment', 'server', or 'servertemplate'")
      end
      data
    end

    #
    # Cloud Data
    #

    def get_cloud_metadata(opts)
      data = {}
      describe_metadata_fields("cloud").each { |f| data["cloud_#{f}"] = [] }
      cloud_names = VirtualMonkey::Toolbox.get_available_clouds.to_h("cloud_id", "name")

      # Define extract_data proc
      extract_data = proc do |cloud_id|
        data["cloud_id"] |= [cloud_id.to_i]
        data["cloud_name"] |= [cloud_names[cloud_id.to_i]]
      end

      # Switch on possible inputs
      if RightScale::Api::Base === opts["cloud"]
        extract_data[opts["cloud"].rs_id]
      elsif RightScale::Api::Base === opts["server"]
        extract_data[opts["server"].cloud_id]
      elsif RightScale::Api::Base === opts["deployment"]
        cloud_identifier = opts["deployment"].get_info_tags["self"]["cloud"]
        if cloud_identifier != "multicloud"
          extract_data[cloud_identifier]
        else
          opts["deployment"].servers_no_reload.each { |s| extract_data[s.cloud_id] }
        end
      else
        raise ArgumentError.new("#{this_method} requires a 'deployment', 'server', or 'cloud'")
      end
      data
    end

    #
    # InstanceType Data
    #

    def ec2_instance_types
      @@ec2_instance_types ||= [
        "t1.micro",
        "m1.small",
        "c1.medium",
        "m1.large",
        "m1.xlarge",
        "m2.xlarge",
        "m2.2xlarge",
        "m2.4xlarge",
        "c1.xlarge",
        "cc1.4xlarge",
        "cc2.8xlarge",
        "cg1.4xlarge",
      ]
    end

    def get_instancetype_metadata(opts)
      data = {}
      describe_metadata_fields("instancetype").each { |f| data["instancetype_#{f}"] = [] }

      # Define extract_data proc
      extract_data = proc do |instancetype|
        if RightScale::Api::Base === instancetype
          data["instancetype_href"] |= [instancetype.href]
          data["instancetype_name"] |= [instancetype.name]
        elsif ec2_instance_types.include?(instancetype)
          data["instancetype_href"] |= [instancetype]
          data["instancetype_name"] |= [instancetype]
        end
      end

      # Switch on possible inputs
      if RightScale::Api::Base === opts["instancetype"] || ec2_instance_types.include?(opts["instancetype"])
        extract_data[opts["instancetype"]]
      elsif RightScale::Api::Base === opts["instance"]
        extract_data[McInstanceType.find(opts["instance"].instance_type)]
      elsif RightScale::Api::Base === opts["server"]
        s = opts["server"]
        if server.multicloud
          hsh = {"instance" => (s.current_instance ? s.current_instance : s.next_instance)}
          data.deep_merge!(send(this_method, opts.merge(hsh)))
        else
          extract_data[s.ec2_instance_type]
        end
      elsif RightScale::Api::Base === opts["deployment"]
        opts["deployment"].servers.each do |s|
          data.deep_merge!(send(this_method, opts.merge("server" => s)))
        end
      else
        raise ArgumentError.new("#{this_method} requires a 'deployment', 'server', 'instance', or 'instancetype'")
      end
      data
    end

    #
    # Datacenter Data
    #

    def get_datacenter_metadata(opts)
      data = {}
      describe_metadata_fields("datacenter").each { |f| data["datacenter_#{f}"] = [] }

      # Define extract_data proc
      extract_data = proc do |datacenter|
        data["datacenter_href"] |= [datacenter.href]
        data["datacenter_name"] |= [datacenter.name]
      end

      # Switch on possible inputs
      if RightScale::Api::Base === opts["datacenter"]
        extract_data[opts["datacenter"]]
      elsif RightScale::Api::Base === opts["instance"]
        extract_data[McDatacenter.find(opts["instance"].datacenter)]
      elsif RightScale::Api::Base === opts["server"]
        if opts["server"].multicloud
          extract_data[McDatacenter.find(opts["server"].datacenter)]
        end
      elsif RightScale::Api::Base === opts["deployment"]
        opts["deployment"].servers.each do |s|
          data.deep_merge!(send(this_method, opts.merge({"server" => s})))
        end
      else
        raise ArgumentError.new("#{this_method} requires a 'deployment', 'server', 'instance', or 'datacenter'")
      end
      data
    end

    ###########################
    # Metadata Syncronization #
    ###########################

    TEMP_STORE = File.join("", "tmp", "rs_account_sync.json").freeze

    def read_cache
      JSON::parse(IO.read(TEMP_STORE))
    rescue Errno::ENOENT, JSON::ParserError
      File.open(TEMP_STORE, "w") { |f| f.write("{}") }
      return {}
    rescue Errno::EBADF, IOError
      sleep 0.1
      retry
    end

    def write_cache(json_hash)
      File.open(TEMP_STORE, "w") { |f| f.write(json_hash.to_json) }
    rescue Errno::EBADF, IOError
      sleep 0.1
      retry
    end

    def synchronize
      rs_resources = [MultiCloudImage, ServerTemplate, Cloud, McInstanceType, McDatacenter]
      metadata_names = ["mci", "servertemplate", "cloud", "instancetype", "datacenter"]
      parent_resources = [nil, nil, nil, Cloud, Cloud]
      max_retries = 5
      write_cache({})
      rs_resources.zip(metadata_names, parent_resources).each do |klass,name,parent_resource|
        begin
          opts = {:skip_rightlink_version_check => true}
          cache = read_cache
          all = []
          if parent_resource
            parent_resource.find_all.each { |item|
              begin
                all += klass.find_all(item.rs_id)
              rescue RestConnection::Errors::UnprocessableEntity => e
                next if e.message =~ /doesn't support/i
                raise
              end
            }
          else
            all = klass.find_all
          end
          begin
            all.map do |item|
              cache.deep_merge!(send("get_#{name}_metadata", opts.merge(name => item)))
            end
          rescue Exception => e
            raise if (max_retries -= 1) < 0
            retry
          end
          write_cache(cache)
        rescue Exception => e
          raise if (max_retries -= 1) < 0
          retry
        end
      end

      all_troops = VirtualMonkey::Manager::Collateral::all_troops.flatten.map { |t| Dir.relative_path(t) }
      begin
        cache = read_cache
        cache["troop"] = all_troops
        write_cache(cache)
      rescue
        raise if (max_retries -= 1) < 0
        retry
      end

      return cache
    end
  end
end
