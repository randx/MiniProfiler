class SqlPatches

  def self.patched?
    @patched
  end

  def self.patched=(val)
    @patched = val
  end

	def self.class_exists?(name)
		eval(name + ".class").to_s.eql?('Class')
	rescue NameError
		false
	end
	
  def self.module_exists?(name)
		eval(name + ".class").to_s.eql?('Module')
	rescue NameError
		false
	end
end

# The best kind of instrumentation is in the actual db provider, however we don't want to double instrument
if SqlPatches.class_exists? "Mysql2::Client"
  
  class Mysql2::Result
    alias_method :each_without_profiling, :each
    def each(*args, &blk)
      return each_without_profiling(*args, &blk) unless @miniprofiler_sql_id

      start = Time.now
      result = each_without_profiling(*args,&blk) 
      elapsed_time = ((Time.now - start).to_f * 1000).round(1)

      @miniprofiler_sql_id.report_reader_duration(elapsed_time) 
      result
    end
  end

  class Mysql2::Client
    alias_method :query_without_profiling, :query
    def query(*args,&blk)
      current = ::Rack::MiniProfiler.current
      return query_without_profiling(*args,&blk) unless current

      start = Time.now
      result = query_without_profiling(*args,&blk)
      elapsed_time = ((Time.now - start).to_f * 1000).round(1)
      result.instance_variable_set("@miniprofiler_sql_id", ::Rack::MiniProfiler.record_sql(args[0], elapsed_time))

      result

    end
  end
    
  SqlPatches.patched = true
end


# PG patches, keep in mind exec and async_exec have a exec{|r| } semantics that is yet to be implemented 
if SqlPatches.class_exists? "PG::Result"
  
  class PG::Result
    alias_method :each_without_profiling, :each
    alias_method :values_without_profiling, :values

    def values(*args, &blk)
      return values_without_profiling(*args, &blk) unless @miniprofiler_sql_id

      start = Time.now
      result = values_without_profiling(*args,&blk) 
      elapsed_time = ((Time.now - start).to_f * 1000).round(1)

      @miniprofiler_sql_id.report_reader_duration(elapsed_time) 
      result
    end

    def each(*args, &blk)
      return each_without_profiling(*args, &blk) unless @miniprofiler_sql_id

      start = Time.now
      result = each_without_profiling(*args,&blk) 
      elapsed_time = ((Time.now - start).to_f * 1000).round(1)

      @miniprofiler_sql_id.report_reader_duration(elapsed_time) 
      result
    end
  end

  class PG::Connection
    alias_method :exec_without_profiling, :exec
    alias_method :async_exec_without_profiling, :async_exec

    def exec(*args,&blk)
      current = ::Rack::MiniProfiler.current
      return exec_without_profiling(*args,&blk) unless current

      start = Time.now
      result = exec_without_profiling(*args,&blk)
      elapsed_time = ((Time.now - start).to_f * 1000).round(1)
      result.instance_variable_set("@miniprofiler_sql_id", ::Rack::MiniProfiler.record_sql(args[0], elapsed_time))

      result
    end

    def async_exec(*args,&blk)
      current = ::Rack::MiniProfiler.current
      return exec_without_profiling(*args,&blk) unless current

      start = Time.now
      result = exec_without_profiling(*args,&blk)
      elapsed_time = ((Time.now - start).to_f * 1000).round(1)
      result.instance_variable_set("@miniprofiler_sql_id", ::Rack::MiniProfiler.record_sql(args[0], elapsed_time))

      result
    end
    
    alias_method :query, :exec
  end
    
  SqlPatches.patched = true
end



# Fallback for sequel
if SqlPatches.class_exists?("Sequel::Database") && !SqlPatches.patched?
	module Sequel
		class Database
			alias_method :log_duration_original, :log_duration
			def log_duration(duration, message)
				::Rack::MiniProfiler.record_sql(message, duration)
				log_duration_original(duration, message)
			end
		end
	end
end


## based off https://github.com/newrelic/rpm/blob/master/lib/new_relic/agent/instrumentation/active_record.rb
## fallback for alls sorts of weird dbs
if SqlPatches.module_exists?('ActiveRecord')
  module Rack
    class MiniProfiler  
      module ActiveRecordInstrumentation
        def self.included(instrumented_class)
          instrumented_class.class_eval do
            unless instrumented_class.method_defined?(:log_without_miniprofiler)
              alias_method :log_without_miniprofiler, :log
              alias_method :log, :log_with_miniprofiler
              protected :log
            end
          end
        end

        def log_with_miniprofiler(*args, &block)
          current = ::Rack::MiniProfiler.current
          return log_without_miniprofiler(*args, &block) unless current

          sql, name, binds = args
          t0 = Time.now
          rval = log_without_miniprofiler(*args, &block)
          
          # Don't log schema queries if the option is set
          return rval if Rack::MiniProfiler.config.skip_schema_queries and name =~ /SCHEMA/

          elapsed_time = ((Time.now - t0).to_f * 1000).round(1)
          Rack::MiniProfiler.record_sql(sql, elapsed_time)
          rval
        end
      end
    end

    def self.insert_instrumentation 
      ActiveRecord::ConnectionAdapters::AbstractAdapter.module_eval do
        include ::Rack::MiniProfiler::ActiveRecordInstrumentation
      end
    end

    if defined?(::Rails) && !SqlPatches.patched?
      insert_instrumentation
    end
  end
end
