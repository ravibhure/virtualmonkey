#--
# Copyright (c) 2012 RightScale, Inc, All Rights Reserved Worldwide.
#
# THIS PROGRAM IS CONFIDENTIAL AND PROPRIETARY TO RIGHTSCALE
# AND CONSTITUTES A VALUABLE TRADE SECRET.  Any unauthorized use,
# reproduction, modification, or disclosure of this program is
# strictly prohibited.  Any use of this program by an authorized
# licensee is strictly subject to the terms and conditions,
# including confidentiality obligations, set forth in the applicable
# License Agreement between RightScale, Inc. and
# the licensee.
#++

########################################################################################################################
# ReportImages mixin module
#
# This module contains all the images used in the rocketmonkey program. This was done because the images
# are encoded and are very long. This makes editing in vim problematic so they are kept here to make
# editing the other source files much more easy in vim.
########################################################################################################################
module ReportImages

  ######################################################################################################################
  # instance method: initialize_images
  ######################################################################################################################
  def initialize_images(snapshot)
    if snapshot
      uri_prefix = "http://s3.amazonaws.com/virtual_monkey/rocketmonkey/images"
    else
      uri_prefix = "http://qaweb.test.rightscale.com/rocketmonkey/images"
    end

    # General images
    @rocket_monkey_image = "#{uri_prefix}/RocketMonkey.jpg"
    @happy_monkey_image = "#{uri_prefix}/HappyMonkey.png"
    @pissed_off_monkey_image = "#{uri_prefix}/MadMonkey.png"
    @right_scale_logo_image = "#{uri_prefix}/RightScaleLogo.png"

    # Matrix images
    @test_has_not_run_yet_image = "#{uri_prefix}/NotRunYet.png"
    @test_running_image = "#{uri_prefix}/Running.gif"
    @test_aborted_image = "#{uri_prefix}/Aborted.png"
    @other_test_failed_image = "#{uri_prefix}/other_failure.png"
    @server_template_test_failed_image = "#{uri_prefix}/server_template_failure.png"
    @test_passed_image = "#{uri_prefix}/Passed.png"
    @test_not_supported_image = "#{uri_prefix}/NotSupported.png"
    @test_not_supported_yet_image = "#{uri_prefix}/NotSupportedYet.png"
    @test_disabled_image = "#{uri_prefix}/Disabled.png"
    @test_action_start_job_image = "#{uri_prefix}/StartJob.png"
    @test_action_stop_job_image = "#{uri_prefix}/StopJob.png"
    @test_question_image = "#{uri_prefix}/Question.png"
  end
end
