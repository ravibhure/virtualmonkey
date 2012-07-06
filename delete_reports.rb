# Us this script to delete all report entries from SimpleDB 
# USE WITH EXTREME CAUTION!!!
#
# Must be run from the root of the virtaul monkey folder tree!

$LOAD_PATH.unshift('lib')

require 'rubygems'
require 'virtualmonkey'

VirtualMonkey::API::Report.index.each do |record|
  begin
    puts "Deleting record #{record["uid"]}..."
    pp record
# To actually delete records, uncomment the following line of code
#    VirtualMonkey::API::Report.delete(record["uid"])
  rescue Excon::Errors::ServiceUnavailable => e
    warn "Message #{e}, retrying..."
    sleep 10
    retry
  end
end
