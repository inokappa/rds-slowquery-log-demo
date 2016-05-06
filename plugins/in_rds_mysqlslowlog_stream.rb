module Fluent
  class InRdsMysqlSlowLogStream < Fluent::Input
    Fluent::Plugin.register_input('rds_mysqlslowlog_stream', self)

    unless method_defined?(:log)
      define_method("log") { $log }
    end

    unless method_defined?(:router)
      define_method("router") { Fluent::Engine }
    end

    config_param :db_instance_identifier, :string
    config_param :log_file_name, :string, :default => "slowquery/mysql-slowquery.log"
    config_param :region, :string, :default => "ap-northeast-1"
    config_param :interval, :integer, :default => 60
    config_param :tag, :string, :default => nil
    config_param :marker_file, :string

    def initialize
      super 
      require "aws-sdk"
      require "mysql-slowquery-parser"
    end

    def start
      @rds = Aws::RDS::Client.new(region: @region)
      @finished = false
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @finished = true
      @thread.join
    end

    private

    def check_marker(marker)
      return nil unless File.exist?(@marker_file)
      current_marker = File.read(@marker_file).chomp
      # p current_marker.class
      # current_marker.include?(marker)
      current_marker == marker
    end

    def write_marker(marker)
      open(@marker_file, 'w') do |f|
        f.write marker
      end
    end

    #
    # reference: https://gist.github.com/ruckus/d30531c543d677eb3acb
    #  
    def get_log
      rawlog = ""
      opts = {
        db_instance_identifier: @db_instance_identifier,
        log_file_name: @log_file_name,
        marker: File.read(@marker_file).chomp
      }

      additional_data_pending = true
      while additional_data_pending  do
        res = @rds.download_db_log_file_portion(opts)
        # p opts[:marker]
        # p res[:marker]
        # p opts
        unless res[:marker] == opts[:marker] then
          # p check_marker(res[:marker])
          # p res[:marker]
          unless check_marker(res[:marker]) then
            opts[:marker] = res[:marker]
            additional_data_pending = res[:additional_data_pending]
            rawlog << res[:log_file_data]
            write_marker(opts[:marker])
          else
            return "already imported."   
            break
          end
        end
      end

      return rawlog
    end
    
    def parse_data(log)
      MySQLSlowQueryParser.parse(log)
    end

    def run
      loop do
        rawlog = get_log
        unless rawlog == "already imported." then
          parse_data(rawlog).each do |log|
            time = log[:datetime]
            router.emit(@tag, time, log)
          end
        end
        sleep @interval
      end
    end

  end
end
