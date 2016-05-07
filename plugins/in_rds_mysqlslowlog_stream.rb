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
    config_param :interval, :integer, :default => 300
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

      File.open(@marker_file, "w").close() unless File.exist?(@marker_file)
    end

    def shutdown
      @finished = true
      @thread.join
    end

    private

    #
    # 無駄に API コールしたくないけど...苦肉の策
    #
    def get_marker
      opts = {
        db_instance_identifier: @db_instance_identifier,
        log_file_name: @log_file_name,
      }
      @rds.download_db_log_file_portion(opts)[:marker]
    end

    def check_marker(marker)
      current_marker = File.read(@marker_file).chomp
      current_marker == marker 
    end

    def write_marker(marker)
      open(@marker_file, 'w') do |f|
        f.write marker
      end
    end

    # ローテーション時の marker 処理
    #   - current_marker と get_marker の UTC 時刻を比較する => 多分不完全
    #     - 一緒だったら current_marker
    #     - 異なっていたら ""
    def define_marker(current_marker)
      if current_marker.split(":")[0] == get_marker.split(":")[0] then
        return current_marker.split
      else
        return current_marker, ""
      end
    end

    #
    # reference: https://gist.github.com/ruckus/d30531c543d677eb3acb
    #  
    def get_log(current_marker)
      rawlog = ""
      
      # p define_marker(current_marker)
      define_marker(current_marker).each do |m|
        opts = {
          db_instance_identifier: @db_instance_identifier,
          log_file_name: @log_file_name,
          # marker: current_marker.split(":")[0] == get_marker.split(":")[0] ? current_marker : ""
          marker: m
        }

        additional_data_pending = true
        while additional_data_pending  do
          # p opts
          res = @rds.download_db_log_file_portion(opts)
          # p check_marker(res[:marker])
          unless check_marker(res[:marker]) then
            opts[:marker] = res[:marker]
            additional_data_pending = res[:additional_data_pending]
            rawlog << res[:log_file_data]
            # p rawlog
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
        current_marker = File.read(@marker_file).chomp
        rawlog = get_log(current_marker)
        #p rawlog
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
