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

# This is the rest_connection mock gem used by the RocketMonkey Test Framework

class Deployment
	attr_accessor :nickname

	def initialize(nickname)
		@nickname = nickname
	end

	@@deployment_array = [
			Deployment.new("test01_AWS_RHEL_002_base"),
			Deployment.new("test01_AWS_RHEL_003_base_linux"),
			Deployment.new("test01_AWS_CentOS_002_base"),
      Deployment.new("test01_AWS_RHEL_005_lamp_chef"),
  ]

	def self.find_all()
		return @@deployment_array
	end

end
