module VirtualMonkey
  module Command
    add_command("import_deployment", [:deployment, :project], [], :flagless) do
      assert_tty
      self.interactive_select_project_logic()

      # Find Model Deployment
      deploy_name = @@options[:deployment]
      if @@options[:deployment]
        deployment = Deployment[deploy_name].first
        puts deployment.nickname
        accepted = ask("Is this the deployment that you wish to import? (y/n)", lambda { |ans| true if (ans =~ /^[yY]{1}/) })
      else
        accepted = false
      end

      while not accepted
        deploy_name = ask("What is the name of this model deployment?")
        deployments = Deployment[/#{deploy_name}/i]
        if deployments.length > 9
          say("Sorry, '#{deploy_name}' is too vague. (Matched more than 9 deployments)")
        elsif deployments.length == 1
          deployment = deployments.first
          accepted = true
        elsif deployments.empty?
          say("Couldn't find any deployment named '#{deploy_name}'.")
        else
          i = choose do |menu|
            menu.prompt = "Which deployment did you mean?"
            menu.index = :number
            menu.choices(*(deployments.map { |d| d.nickname }))
          end
          deployment = deployments[i.to_i - 1]
          accepted = true
        end
      end
      deployment.servers.each { |s| s.settings }

      # Build Scenario Names
      build_scenario_names(deployment.nickname)

      # Build Troop Config and Script_Array
      build_troop_config(deployment)


      # Extract Inputs from Deployment
      @@common_inputs = {}
      if VirtualMonkey::Toolbox::api1_5?
        mc_deployment = McDeployment.find(deployment.rs_id.to_i)
        mc_deployment.show
        mc_deployment.get_inputs.each { |hsh|
          @@common_inputs[hsh["name"]] = hsh["value"] unless hsh["value"] == "text:"
        }
      end

      # Extract Common Inputs from Servers
      server_inputs = {}
      @@individual_server_inputs = {}
      add_set_input_fn = false
      deployment.servers_no_reload.each { |s|
        s.settings
        if s.multicloud
          instance = s.next_instance
          instance = s.current_instance if s.current_instance
          instance.get_inputs.each { |hsh|
            if server_inputs[hsh["name"]]
              if server_inputs[hsh["name"]] != hsh["value"]
                server_inputs[hsh["name"]] = "text:"
              end
            else
              server_inputs[hsh["name"]] = hsh["value"]
            end
            @@individual_server_inputs[s.rs_id] ||= {}
            @@individual_server_inputs[s.rs_id][hsh["name"]] = hsh["value"]
          }
          add_set_input_fn ||= true
        elsif s.current_instance_href
          s.reload_as_current
          s.settings
          s.parameters.each { |input_name,input_value|
            if server_inputs[input_name]
              if server_inputs[input_name] != input_value
                server_inputs[input_name] = "text:"
              end
            else
              server_inputs[input_name] = input_value
            end
          }
          @@individual_server_inputs[s.rs_id] = s.parameters.dup
          s.reload_as_next
          add_set_input_fn ||= true
        end
      }
      server_inputs.reject! { |name,value| value == "text:" }
      @@common_inputs.deep_merge! server_inputs # Server inputs always overwrite deployment inputs

      @@common_inputs.reject! { |name,value| value == "text:" }
      if @@common_inputs.empty?
        write_common_inputs_file()
      else
        write_common_inputs_file(@@common_inputs)
      end

      # Create files
      write_feature_file()
      write_troop_file()
      write_mixin_file()
      write_runner_file(add_set_input_fn)

      say("Created common_inputs file:  #{@@common_inputs_file}")
      say("Created feature file:        #{@@feature_file}")
      say("Created config file:         #{@@troop_file}")
      say("Created mixin file:          #{@@mixin_file}")
      say("Created runner file:         #{@@runner_file}")

      say("\nScenario created! DON'T FORGET TO CUSTOMIZE THESE FILES!");

      # Refresh Projects index
      VirtualMonkey::Manager::Collateral.refresh()
    end
  end
end
