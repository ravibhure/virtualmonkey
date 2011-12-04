module VirtualMonkey
  module Command
    add_command("new_runner", [:project], [], :flagless) do
      assert_tty
      interactive_select_project_logic()

      build_scenario_names()
      build_troop_config()
      write_common_inputs_file()
      write_feature_file()
      write_troop_file()
      write_mixin_file()
      write_runner_file()

      say("Created common_inputs file:  #{@@common_inputs_file}")
      say("Created feature file:        #{@@feature_file}")
      say("Created config file:         #{@@troop_file}")
      say("Created mixin file:          #{@@mixin_file}")
      say("Created runner file:         #{@@runner_file}")

      say("\nScenario created! DON'T FORGET TO CUSTOMIZE THESE FILES!")

      # Refresh Projects index
      VirtualMonkey::Manager::Collateral.refresh()
    end
  end
end
