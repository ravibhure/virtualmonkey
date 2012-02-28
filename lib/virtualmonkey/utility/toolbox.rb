progress_require('timeout')

#
# Figure out REACHABLE_IP
#

def load_self_reachable_ip
  if ENV['SSH_CONNECTION'] # LINUX ONLY
    ENV['REACHABLE_IP'] = ENV['SSH_CONNECTION'].split(/ /)[-2]
  else
    possible_ips = `ifconfig | grep -o "inet addr:[0-9\.]*" | grep -o "[0-9\.]*$"`.split(/\n/)
    possible_ips.reject! { |ip| ip == "127.0.0.1" }
    ENV['REACHABLE_IP'] = possible_ips.first
  end
end

load_self_reachable_ip()

#
# Import user and metadata if we're in the cloud
#

if File.exists?("/var/spool/cloud/meta-data.rb")
  require '/var/spool/cloud/user-data'
  require '/var/spool/cloud/meta-data-cache'
  if ENV['RS_API_URL'] # AWS
    ENV['I_AM_IN_EC2'] = "true"
  elsif File.exists?("/etc/rightscale.d/cloud")
    ENV['CLOUD_TYPE'] = IO.read("/etc/rightscale.d/cloud").chomp
    case ENV['CLOUD_TYPE']
    when "eucalyptus", "cloudstack", "rackspace"
      Timeout::timeout(300) { (load_self_reachable_ip(); sleep 5) until ENV['REACHABLE_IP'] }
      ENV['RS_API_URL'] = "#{`hostname`.strip}-#{ENV['REACHABLE_IP'].gsub(/\./, "-")}" # LINUX ONLY
      ENV['I_AM_IN_MULTICLOUD'] = "true"
    else
      `wall "FATAL: New cloud_type detected: '#{ENV['CLOUD_TYPE']}'"`
    end
  end
elsif File.exists?("/var/spool/cloud/user-data.rb")
  require '/var/spool/cloud/user-data'
  Timeout::timeout(300) { (load_self_reachable_ip(); sleep 5) until ENV['REACHABLE_IP'] }
  ENV['RS_API_URL'] = "#{`hostname`.strip}-#{ENV['REACHABLE_IP'].gsub(/\./, "-")}" # LINUX ONLY
  ENV['I_AM_IN_MULTICLOUD'] = "true"
else
  ENV['RS_API_URL'] = "#{ENV['USER']}-#{`hostname`}".strip # LINUX ONLY
end

#
# Main Module
#

module VirtualMonkey
  @@my_api_self = nil

  def self.my_api_self
    @@my_api_self = VirtualMonkey::Toolbox::find_myself_in_api if @@my_api_self.nil?
    @@my_api_self
  end

  module Toolbox
    extend self

    # Check for API 0.1 Access
    def api0_1?
      unless class_variable_defined?("@@api0_1")
        begin
          Ec2SshKeyInternal.find_all
          @@api0_1 = true
        rescue
          @@api0_1 = false
        end
      end
      return @@api0_1
    end

    # Check for API 1.0 Access
    def api1_0?
      unless class_variable_defined?("@@api1_0")
        begin
          Ec2SecurityGroup.find_all
          @@api1_0 = true
        rescue
          @@api1_0 = false
        end
      end
      return @@api1_0
    end

    # Check for API 1.5 Beta Access
    def api1_5?
      unless class_variable_defined?("@@api1_5")
        begin
          Cloud.find_all
          @@api1_5 = true
        rescue
          @@api1_5 = false
        end
      end
      return @@api1_5
    end

    # Initializes most of the important class variables
    def setup_paths
      # This sets up the Framework's cloud_var dir so it doesn't interfere with collateral-specific cloud_vars
      @@cloud_vars_dir = VirtualMonkey::GENERATED_CLOUD_VAR_DIR
      FileUtils.mkdir_p(@@cloud_vars_dir)
      @@ssh_dir = File.expand_path(File.join("~", ".ssh"))
      @@sgs_file = File.join(@@cloud_vars_dir, "security_groups.json")
      @@its_file = File.join(@@cloud_vars_dir, "instance_types.json")
      @@dcs_file = File.join(@@cloud_vars_dir, "datacenters.json")
      @@keys_file = File.join(@@cloud_vars_dir, "ssh_keys.json")
      @@ssh_key_file_basename = "monkey-cloud-"
    end

    # Query for available clouds
    def get_available_clouds(up_to = 1000000)
      setup_paths()
      unless class_variable_defined?("@@clouds")
        @@clouds = [
                    {"cloud_id" => 1, "name" => "AWS US-East"},
                    {"cloud_id" => 2, "name" => "AWS EU"},
                    {"cloud_id" => 3, "name" => "AWS US-West"},
                    {"cloud_id" => 4, "name" => "AWS AP-Singapore"},
                    {"cloud_id" => 5, "name" => "AWS AP-Tokyo"},
                    {"cloud_id" => 6, "name" => "AWS US-Oregon"},
                    {"cloud_id" => 7, "name" => "AWS SA-Sao Paulo"},
                   ]
        @@clouds += Cloud.find_all.map { |c| {"cloud_id" => c.cloud_id.to_i, "name" => c.name} } if api1_5?
      end
      @@clouds.select { |h| h["cloud_id"] <= up_to }
    end

    # Determine cloud_id for a server regardless of if it's operational or not
    def determine_cloud_id(server)
      server.settings
      ret = nil
      return server.cloud_id if server.cloud_id
      # API 1.5 has cloud_id under .settings even on inactive server, so must be API 1.0
      cloud_ids = get_available_clouds(10).map { |hsh| hsh["cloud_id"] }

      # Try ssh keys
      if server.ec2_ssh_key_href and api0_1?
        ref = server.ec2_ssh_key_href
        cloud_ids.each { |cloud|
          if Ec2SshKeyInternal.find_by_cloud_id(cloud.to_s).select { |o| o.href == ref }.first
            ret = cloud
          end
        }
      end

      return ret if ret
      # Try security groups
      if server.ec2_security_groups_href
        server.ec2_security_groups_href.each { |sg|
          cloud_ids.each { |cloud|
            if Ec2SecurityGroup.find_by_cloud_id(cloud.to_s).select { |o| o.href == sg }.first
              ret = cloud
            end
          }
        }
      end

      return ret if ret
      raise "Could not determine cloud_id...try setting an ssh key or security group"
    end

    # If virtualmonkey is running in EC2, sets some environment variables and returns a Server object for itself
    def find_myself_in_api
      if ENV['I_AM_IN_EC2']
        myself = Server.find_with_filter('aws_id' => ENV['EC2_INSTANCE_ID']).first
        if myself
          myself.settings
          my_deploy = Deployment.find(myself.deployment_href)
          ENV['MONKEY_SELF_SERVER_HREF'] = myself.href
          ENV['MONKEY_SELF_DEPLOYMENT_HREF'] = my_deploy.href
          ENV['MONKEY_SELF_DEPLOYMENT_NAME'] = my_deploy.nickname
          return ServerInterface.new(myself.cloud_id, myself.params)
        end
      elsif ENV['I_AM_IN_MULTICLOUD']
        cloud_ids = get_available_clouds().map { |hsh| hsh["cloud_id"].to_i }.reject { |cid| cid < 10 }
        ip_fields = [:public_dns_name, :public_ip_address, :private_dns_name, :private_ip_address]
        ssh_address = ENV['REACHABLE_IP']
        my_instance = nil
        cloud_ids.each { |cid|
          ip_fields.each { |field|
            my_instance = McInstance.find_with_filter(cid, field => ssh_address).first
            if my_instance
              my_instance.show
              if my_instance.user_data.include?(ENV['RS_RN_URL'])
                # Found myself, let's get servers, etc.
                myself = McServer.find(my_instance.parent)
                myself.settings
                my_deploy = McDeployment.find(myself.deployment_href)
                ENV['MONKEY_SELF_SERVER_HREF'] = myself.href
                ENV['MONKEY_SELF_DEPLOYMENT_HREF'] = my_deploy.href
                ENV['MONKEY_SELF_DEPLOYMENT_NAME'] = my_deploy.name
                return ServerInterface.new(myself.cloud_id, myself.params)
              end
            end
          }
        }
      end
      return false
    end

    # Generates temporary ssh keys to use for ssh'ing into generated servers. ssh_key_id_ary is a Hash of
    # the form: {"1" => "0000", "2" => "0001", ... } or nil
    # NOTE: for some reason, you looked up `git ls-files`
    def generate_ssh_keys(cloud_id_set=nil, overwrite=false, force=false, ssh_key_id_ary=nil)
      cloud_ids = get_available_clouds().map { |hsh| hsh["cloud_id"] }
      cloud_ids &= [cloud_id_set].flatten.compact unless [cloud_id_set].flatten.compact.empty?
      return puts("No clouds to generate ssh keys for") if cloud_ids.empty?
      puts "Generating SSH Keys for clouds: #{cloud_ids.join(", ")}"

      ssh_key_id_ary ||= {}
      multicloud_key_file = File.join(@@ssh_dir, "api_user_key")
      rest_settings = YAML::load(IO.read(VirtualMonkey::REST_YAML))
      rest_settings[:ssh_keys] = [] unless rest_settings[:ssh_keys]
      multicloud_key_data = IO.read(multicloud_key_file) if File.exists?(multicloud_key_file)
      keys = {}
      keys = JSON::parse(IO.read(@@keys_file)) if File.exists?(@@keys_file)

      cloud_ids.each { |cloud|
        begin
          if keys["#{cloud}"] and keys["#{cloud}"] != {}
            if overwrite
              destroy_ssh_keys(cloud)
            else
              # We already have data for this cloud, skip
              puts "Data found for cloud #{cloud}. Skipping..."
              next
            end
          end
          key_name = "monkey-#{cloud}-#{ENV['RS_API_URL'].split("/").last}"
          found = nil
          if cloud <= 10
            if api0_1?
              found = Ec2SshKeyInternal.find_by_cloud_id("#{cloud}").select { |o| o.aws_key_name =~ /#{key_name}/ }.first
            end
            if ssh_key_id_ary[cloud.to_i]
              k = Ec2SshKey[ssh_key_id_ary[cloud.to_i].to_i].first
            else
              k = (found ? found : Ec2SshKey.create('aws_key_name' => key_name, 'cloud_id' => "#{cloud}"))
            end
            keys["#{cloud}"] = {"ec2_ssh_key_href" => k.href,
                                "parameters" =>
                                  {"PRIVATE_SSH_KEY" => "key:#{key_name}:#{cloud}"}
                                }
            # Generate Private Key Files
            priv_key_file = File.join(@@ssh_dir, "#{@@ssh_key_file_basename}#{cloud}")
            File.open(priv_key_file, "w") { |f| f.write(k.aws_material) } unless File.exists?(priv_key_file)
          else
            keys["#{cloud}"] = {}
=begin
            TODO Uncomment once API 1.5 supports returning the key material
            if Cloud.find(cloud).ssh_keys
              # Multicloud Resource that supports SSH Keys
              found = McSshKey.find_by(:resource_uid, "#{cloud}") { |n| n =~ /#{key_name}/ }.first
              if ssh_key_id_ary[cloud.to_i]
                k = McSshKey[ssh_key_id_ary[cloud.to_i].to_i].first
              else
                k = (found ? found : McSshKey.create('name' => key_name, 'cloud_id' => "#{cloud}"))
              end
              keys["#{cloud}"]["ssh_key_href"] = k.href
              priv_key_file = File.join(@@ssh_dir, "#{@@ssh_key_file_basename}#{cloud}")
              File.open(priv_key_file, "w") { |f| f.write(#TODO key_material) } unless File.exists?(priv_key_file)
            else
=end
              # Use API user's managed ssh key
              puts "Using API user's managed ssh key, make sure \"~/.ssh/#{multicloud_key_file}\" exists!"
              if api0_1? and Ec2SshKeyInternal.find_by_cloud_id(1).select { |o| o.aws_key_name =~ /publish-test/ }.first
                keys["#{cloud}"]["parameters"] = {"PRIVATE_SSH_KEY" => "key:publish-test:1"}
              end
=begin
              begin
                found = McSshKey.find_by(:resource_uid, "#{cloud}") { |n| n =~ /publish-test/ }.first
                if ssh_key_id_ary[cloud.to_i]
                  k = McSshKey[ssh_key_id_ary[cloud.to_i].to_i].first
                else
                  k = (found ? found : McSshKey.create('name' => "publish-test", 'cloud_id' => "#{cloud}"))
                end
                keys["#{cloud}"]["ssh_key_href"] = k.href
              rescue
                puts "Cloud #{cloud} doesn't support the resource 'ssh_key'"
              end
=end
              warn "Cloud #{cloud} doesn't support the resource 'ssh_key'" unless Cloud.find(cloud).ssh_keys
              priv_key_file = multicloud_key_file
#            end #TODO Uncomment once API 1.5 supports returning the key material
          end

          FileUtils.touch(priv_key_file)
          File.chmod(0700, priv_key_file)
          # Configure rest_connection config
          rest_settings[:ssh_keys] |= [priv_key_file]
        rescue Interrupt
          raise
        rescue Exception => e
          raise unless force
          warn "WARNING: Got \"#{e.message}\". Forcing continuation..."
        end
      }

      keys_out = keys.to_json(:indent => "  ", :object_nl => "\n", :array_nl => "\n")
      rest_out = rest_settings.to_yaml
      File.open(@@keys_file, "w") { |f| f.write(keys_out) }
      File.open(VirtualMonkey::REST_YAML, "w") { |f| f.write(rest_out) }
    end

    # Destroys all monkey-generated ssh keys that are not in use by monkey-generated servers
    # NOTE: This is a dangerous, and slow function. Be absolutely sure this is what you want to do.
    def destroy_all_unused_monkey_keys
      raise "You cannot run this without API 0.1 Access" unless api0_1?
      cloud_ids = get_available_clouds(10).map { |hsh| hsh["cloud_id"] }

      puts "Go grab a snickers. This will take a while."
      monkey_keys = []
      cloud_ids.each { |c|
        monkey_keys += Ec2SshKeyInternal.find_by_cloud_id("#{c}").select { |obj| obj.aws_key_name =~ /monkey/ }
      }
      remaining_keys = monkey_keys.map { |k| k.href }

      all_servers = Server.find_all

      all_servers.each { |s|
        s.settings
        remaining_keys.reject! { |k| k.href == s.ec2_ssh_key_href }
      }
      remaining_keys.each { |href| Ec2SshKey.new('href' => href).destroy }
    end

    # Destroys this monkey's temporary generated ssh keys
    def destroy_ssh_keys(cloud_id_set=nil, force=false)
      # TODO: Remove "10" once API1.5 supports key material lookup
      cloud_ids = get_available_clouds(10).map { |hsh| hsh["cloud_id"] }
      cloud_ids &= [cloud_id_set].flatten.compact unless [cloud_id_set].flatten.compact.empty?
      return puts("No clouds to destroy ssh keys for") if cloud_ids.empty?
      puts "Destroying SSH Keys for clouds: #{cloud_ids.join(", ")}"

      rest_settings = YAML::load(IO.read(VirtualMonkey::REST_YAML))

      # Find key_hrefs
      key_name = "#{ENV['RS_API_URL'].split("/").last}"
      if api0_1?
        found = []
        cloud_ids.each { |c|
          found += Ec2SshKeyInternal.find_by_cloud_id("#{c}").select { |obj| obj.aws_key_name =~ /#{key_name}/ }
        }
        key_hrefs = found.select { |k| k.aws_key_name =~ /monkey/ }.map { |k| k.href }
      elsif File.exists?(@@keys_file)
        keys = JSON::parse(IO.read(@@keys_file))
        keys.reject! { |cloud,hash| hash["ec2_ssh_key_href"].nil? and not cloud_ids.include?(cloud.to_i) }
        key_hrefs = keys.map { |cloud,hash| hash["ec2_ssh_key_href"] }
      else
        raise "FATAL: Can't determine any ssh_key hrefs"
      end

      # Delete keys from API
      key_hrefs.each { |href|
        begin
          temp_key = Ec2SshKey.new('href' => href)
          temp_key.reload
          temp_key.destroy if temp_key.aws_key_name =~ /monkey/
        rescue Interrupt
          raise
        rescue Exception => e
          raise unless force
          warn "WARNING: Got \"#{e.message}\". Forcing continuation..."
        end
      }

      # Delete key files from user's ssh dir and references from user's rest_yaml file
      if rest_settings[:ssh_keys]
        rest_settings[:ssh_keys].reject! do |f|
          ret = (f =~ /#{@@ssh_key_file_basename}(#{cloud_ids.join("|")})$/)
          File.delete(f) if File.exists?(f) and ret
          ret
        end
        File.open(VirtualMonkey::REST_YAML, "w") { |f| f.write(rest_settings.to_yaml) }
      end

      # Delete keys from cloud_variables file
      if File.exists?(@@keys_file)
        keys_info = JSON::parse(IO.read(@@keys_file))
        cloud_ids.each { |cloud| keys_info.delete("#{cloud}") }
        if keys_info.empty?
          File.delete(@@keys_file)
        else
          keys_out = keys_info.to_json(:indent => "  ", :object_nl => "\n", :array_nl => "\n")
          File.open(@@keys_file, "w") { |f| f.write(keys_out) }
        end
      end
    end

    # If this virtualmonkey is in EC2, will grab the same security groups attached to it to use for
    # generated servers (requires the same security group name in each cloud). Will default to the 'default'
    # security group for every cloud that doesn't have the named security group. use_this_sec_group should
    # be a string, or nil.
    def populate_security_groups(cloud_id_set=nil, use_this_sec_group=nil, overwrite=false, force=false)
      cloud_ids = get_available_clouds().map { |hsh| hsh["cloud_id"] }
      cloud_ids &= [cloud_id_set].flatten.compact unless [cloud_id_set].flatten.compact.empty?
      return puts("No clouds to populate security groups for") if cloud_ids.empty?
      puts "Populating Security Groups for clouds: #{cloud_ids.join(", ")}"

      sgs = (File.exists?(@@sgs_file) ? JSON::parse(IO.read(@@sgs_file)) : {})

      cloud_ids.each { |cloud|
        begin
          if sgs["#{cloud}"] and sgs["#{cloud}"] != {} and not overwrite
            # We already have data for this cloud, skip
            puts "Data found for cloud #{cloud}. Skipping..."
            next
          end
          if VirtualMonkey::my_api_self
            if ENV['I_AM_IN_EC2']
              my_sec_group = ENV['EC2_SECURITY_GROUPS']
            elsif ENV['I_AM_IN_MULTICLOUD'] and VirtualMonkey::my_api_self.security_groups
              my_sec_group = VirtualMonkey::my_api_self.security_groups.first["href"]
            else
              my_sec_group = nil
            end
          end
          sg_name = "#{use_this_sec_group || my_sec_group || 'monkey'}"
          puts "Looking for the '#{sg_name}' security group in all supporting clouds."
          if cloud <= 10
            cloud_security_groups = Ec2SecurityGroup.find_by_cloud_id("#{cloud}")
            found = cloud_security_groups.detect { |sg| sg.aws_group_name =~ /#{sg_name}/ }
            found ||= cloud_security_groups.detect { |sg| sg.aws_group_name =~ /monkey/ }
            found ||= cloud_security_groups.detect { |sg| sg.aws_group_name =~ /default/ }
            raise "Security Group 'default' not found in cloud #{cloud}." unless found
            puts "Using Security Group '#{found.aws_group_name}' for cloud #{cloud}."
            sgs["#{cloud}"] = {"ec2_security_groups_href" => found.href }
          else
            begin
              cloud_security_groups = McSecurityGroup.find_all("#{cloud}")
              found = cloud_security_groups.detect { |sg| sg.name =~ /#{sg_name}/ }
              found ||= cloud_security_groups.detect { |sg| sg.name =~ /monkey/ }
              found ||= cloud_security_groups.detect { |sg| sg.name =~ /default/ }
              raise "Security Group 'default' not found in cloud #{cloud}." unless found
              puts "Using Security Group '#{found.name}' for cloud #{cloud}."
              sgs["#{cloud}"] = {"security_group_hrefs" => [found.href] }
            rescue Exception => e
              raise if e.message =~ /Security Group.*not found/
              warn "Cloud #{cloud} doesn't support the resource 'security_group'"
              sgs["#{cloud}"] = {}
            end
          end
        rescue Interrupt
          raise
        rescue Exception => e
          raise unless force
          warn "WARNING: Got \"#{e.message}\". Forcing continuation..."
        end
      }

      sgs_out = sgs.to_json(:indent => "  ",
                            :object_nl => "\n",
                            :array_nl => "\n")

      File.open(@@sgs_file, "w") { |f| f.write(sgs_out) }
    end

    # Grabs the API hrefs of the instance_types for each cloud. API 1.5 only
    def populate_instance_types(cloud_id_set=nil, overwrite=false, force=false)
      cloud_ids = get_available_clouds().map { |hsh| hsh["cloud_id"] }
      cloud_ids &= [cloud_id_set].flatten.compact unless [cloud_id_set].flatten.compact.empty?
      return puts("No clouds to populate instance_types for") if cloud_ids.empty?
      puts "Populating InstanceTypes for clouds: #{cloud_ids.join(", ")}"

      its = (File.exists?(@@its_file) ? JSON::parse(IO.read(@@its_file)) : {})

      cloud_ids.each { |cloud|
        begin
          if its["#{cloud}"] and its["#{cloud}"] != {} and not overwrite
            # We already have data for this cloud, skip
            puts "Data found for cloud #{cloud}. Skipping..."
            next
          end
          if cloud <= 10
            warn "Cloud #{cloud} doesn't support the resource 'instance_type'"
            its["#{cloud}"] = {}
          elsif api1_5?
            begin
              i_types = McInstanceType.find_all(cloud)
              select_itype = i_types[i_types.length / 2]
              its["#{cloud}"] = {"instance_type_href" => select_itype.href}
            rescue
              warn "Cloud #{cloud} doesn't support the resource 'instance_type'"
              its["#{cloud}"] = {}
            end
          end
        rescue Interrupt
          raise
        rescue Exception => e
          raise unless force
          warn "WARNING: Got \"#{e.message}\". Forcing continuation..."
        end
      }

      its_out = its.to_json(:indent => "  ",
                            :object_nl => "\n",
                            :array_nl => "\n")

      File.open(@@its_file, "w") { |f| f.write(its_out) }
    end

    # Grabs the API hrefs of the datacenters for each cloud. API 1.5 only
    def populate_datacenters(cloud_id_set=nil, overwrite=false, force=false)
      cloud_ids = get_available_clouds().map { |hsh| hsh["cloud_id"] }
      cloud_ids &= [cloud_id_set].flatten.compact unless [cloud_id_set].flatten.compact.empty?
      return puts("No clouds to populate datacenters for") if cloud_ids.empty?
      puts "Populating Datacenters for clouds: #{cloud_ids.join(", ")}"

      dcs = (File.exists?(@@dcs_file) ? JSON::parse(IO.read(@@dcs_file)) : {})

      cloud_ids.each { |cloud|
        begin
          if dcs["#{cloud}"] and dcs["#{cloud}"] != {} and not overwrite
            # We already have data for this cloud, skip
            puts "Data found for cloud #{cloud}. Skipping..."
            next
          end
          if cloud <= 10
            warn "Cloud #{cloud} doesn't support the resource 'datacenter'"
            dcs["#{cloud}"] = {}
          elsif api1_5?
            begin
              #TODO: Don't just take the first one, Datacenters are variations too (as are Hypervisors)
              found = McDatacenter.find_all("#{cloud}").first.href
              if VirtualMonkey::my_api_self and ENV['I_AM_IN_MULTICLOUD']
                if VirtualMonkey::my_api_self.cloud_id == cloud
                  if VirtualMonkey::my_api_self.current_instance.datacenter
                    found = VirtualMonkey::my_api_self.current_instance.datacenter
                  end
                end
              end
              dcs["#{cloud}"] = {"datacenter_href" => found}
            rescue
              warn "Cloud #{cloud} doesn't support the resource 'datacenter'"
              dcs["#{cloud}"] = {}
            end
          end
        rescue Interrupt
          raise
        rescue Exception => e
          raise unless force
          warn "WARNING: Got \"#{e.message}\". Forcing continuation..."
        end
      }

      dcs_out = dcs.to_json(:indent => "  ",
                            :object_nl => "\n",
                            :array_nl => "\n")

      File.open(@@dcs_file, "w") { |f| f.write(dcs_out) }
    end

    # Populates all cloud_vars (ssh_keys, security_groups, and datacenters) without overriding any manually
    # defined resources
    def populate_all_cloud_vars(cloud_id_set=nil, options={})
      get_available_clouds()
      cloud_ids = @@clouds.map { |hsh| hsh["cloud_id"] }
      cloud_ids &= [cloud_id_set].flatten.compact unless [cloud_id_set].flatten.compact.empty?
      cloud_names = @@clouds.map { |hsh| [hsh["cloud_id"], hsh["name"]] }.to_h

      aws_clouds = {}
      all_clouds = {}

      generate_ssh_keys(cloud_ids, options[:overwrite], options[:force], options[:ssh_key_ids])
      populate_security_groups(cloud_ids, options[:security_group_name], options[:overwrite], options[:force])
      populate_instance_types(cloud_ids, options[:overwrite], options[:force])
      populate_datacenters(cloud_ids, options[:overwrite], options[:force])

      cloud_ids.each { |id|
        name = cloud_names[id].gsub(/[- ]/, "_").gsub(/_+/, "_").downcase
        single_file_name = File.join(@@cloud_vars_dir, "#{name}.json")

        single_cloud_vars = {"#{id}" => {}}
        single_cloud_vars = JSON::parse(IO.read(single_file_name)) if File.exists?(single_file_name)
        # Single File
        single_cloud_out = single_cloud_vars.to_json(:indent => "  ", :object_nl => "\n", :array_nl => "\n")
        # AWS Clouds
        aws_clouds.deep_merge!(single_cloud_vars) if id <= 10
        # All Clouds
        all_clouds.deep_merge!(single_cloud_vars)

        File.open(single_file_name, "w") { |f| f.write(single_cloud_out) }
      }

      aws_clouds_out = aws_clouds.to_json(:indent => "  ", :object_nl => "\n", :array_nl => "\n")
      all_clouds_out = all_clouds.to_json(:indent => "  ", :object_nl => "\n", :array_nl => "\n")
      File.open(File.join(@@cloud_vars_dir, "aws_clouds.json"), "w") { |f| f.write(aws_clouds_out) }
      File.open(File.join(@@cloud_vars_dir, "all_clouds.json"), "w") { |f| f.write(all_clouds_out) }
    end

    def new_sdb_connection
      if Fog.credentials[:aws_access_key_id_test] && Fog.credentials[:aws_secret_access_key_test]
        return Fog::AWS::SimpleDB.new(:aws_access_key_id => Fog.credentials[:aws_access_key_id_test],
                                      :aws_secret_access_key => Fog.credentials[:aws_secret_access_key_test])
      else
        return Fog::AWS::SimpleDB.new()
      end
    end

    def new_s3_connection
      if Fog.credentials[:aws_access_key_id_test] && Fog.credentials[:aws_secret_access_key_test]
        return Fog::Storage.new(:provider => "AWS",
                                :aws_access_key_id => Fog.credentials[:aws_access_key_id_test],
                                :aws_secret_access_key => Fog.credentials[:aws_secret_access_key_test])
      else
        return Fog::Storage.new(:provider => "AWS")
      end
    end

    def get_cloud_instance_type_capacity_data()
      ret = {}
      Cloud.find_all.each { |c|
        cloud_id = c.rs_id.to_i
        ret[cloud_id] = {
          "name" => c.name,
          "instances" => {}
        }
        McInstanceType.find_all(cloud_id).each { |t|
          ret[cloud_id]["instances"][t.href] = {
            "disk" => t.local_disk_size,
            "cpu" => t.cpu_count,
            "memory" => t.memory,
            "name" => t.name
          }
        }
      }

      return ret
    end
  end
end
