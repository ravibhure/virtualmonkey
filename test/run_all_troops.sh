#!/bin/bash -x
LOG="batch_run.log"
[[ -n "$COMMAND" ]] || COMMAND="troop"

bin/monkey collateral checkout servertemplate_tests sprint30

touch ~/base_chef.json.$LOG
if [[ "$COMMAND" == "destroy" ]]; then
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/base_chef.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y &> ~/base_chef.json.$LOG &
else
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/base_chef.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y --report-metadata -r &> ~/base_chef.json.$LOG &
fi

touch ~/lamp_chef.json.$LOG
if [[ "$COMMAND" == "destroy" ]]; then
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/lamp_chef.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y &> ~/lamp_chef.json.$LOG &
else
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/lamp_chef.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y --report-metadata -r &> ~/lamp_chef.json.$LOG &
fi

touch ~/php_suite.json.$LOG
if [[ "$COMMAND" == "destroy" ]]; then
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/php_suite.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y &> ~/php_suite.json.$LOG &
else
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/php_suite.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y --report-metadata -r &> ~/php_suite.json.$LOG &
fi

touch ~/dr_toolbox.json.$LOG
if [[ "$COMMAND" == "destroy" ]]; then
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/dr_toolbox.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y &> ~/dr_toolbox.json.$LOG &
else
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/dr_toolbox.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y --report-metadata -r &> ~/dr_toolbox.json.$LOG &
fi

touch ~/mysql_HAHAHA_chef.json.$LOG
if [[ "$COMMAND" == "destroy" ]]; then
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/mysql_HAHAHA_chef.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y &> ~/mysql_HAHAHA_chef.json.$LOG &
else
  nohup bin/monkey $COMMAND -f collateral/servertemplate_tests/troops/11H2/mysql_HAHAHA_chef.json -x FULL_TESTING -i 1 232 -o "CentOS.*x64" -v -y --report-metadata -r -t "smoke_test" "secondary_restore_and_become_master_cloudfiles" &> ~/mysql_HAHAHA_chef.json.$LOG &
fi
