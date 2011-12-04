module VirtualMonkey
  module Command
    add_command("new_troop_config", [:project], [], :flagless) do
      assert_tty
      self.interactive_select_project_logic()

      # PATHs SETUP
      features_glob = @@selected_project.features.map { |c| File.basename(c) }
      cloud_variables_glob = @@selected_project.cloud_variables.map { |c| File.basename(c) }
      common_inputs_glob = @@selected_project.common_inputs.map { |c| File.basename(c) }
      name = ask("Filename?").strip
      @@troop_file = File.join(@@selected_project.paths["troops"], "#{name}.json")

      # CREATE NEW CONFIG
      @@troop_config = {}
      @@troop_config[:prefix] = ask("What prefix to use for creating the deployments?".word_wrap)
      @@troop_config[:server_template_ids] = ask("What Server Template ids (or names) would you like to use to create the deployments (comma delimited)?".word_wrap).split(",")
      @@troop_config[:server_template_ids].each {|st| st.strip!}

      # TODO: Multicloud Deployments
      puts "Available Clouds:"
      VirtualMonkey::Toolbox::get_available_clouds().each { |c| puts "#{c['cloud_id']}: #{c['name']}" }
      list_of_clouds = ask("Enter a comma-separated list of cloud_ids to use".word_wrap).split(",")
      @@troop_config[:clouds] = list_of_clouds.map { |c| c.to_i }

      puts ("You can select multiple common_inputs files to include. " +
            "Keep in mind that if the same input is defined in multiple files, " +
            "the latest file takes precedence.").word_wrap
      choices = []
      begin
        while true
          choices << choose do |menu|
            menu.prompt = "Which common_inputs file? (Ctrl-C to end)".word_wrap
            menu.index = :number
            menu.choices(*common_inputs_glob)
          end
        end
      rescue Interrupt
      end
      @@troop_config[:common_inputs] = choices

      puts ("You can select multiple feature files to include. " +
            "Please read the documentation if you wish to use multiple feature files, " +
            "they may not behave exactly like you expect them to.").word_wrap
      choices = []
      begin
        while true
          choices << choose do |menu|
            menu.prompt = "Which feature file? (Ctrl-C to end)".word_wrap
            menu.index = :number
            menu.choices(*features_glob)
          end
        end
      rescue Interrupt
      end
      @@troop_config[:feature] = choices

      write_troop_file()
      say("Created config file: #{@@troop_file}")

      # Refresh Projects index
      VirtualMonkey::Manager::Collateral.refresh()
    end
  end
end
