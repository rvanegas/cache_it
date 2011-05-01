
module ActiveRecord
  class Base
    #
    # First time called, configures \cache_it for this ActiveRecord model.
    # Subsequent calls returns a delegate to access class methods.
    #
    # Examples:
    # 
    #   class Foo < ActiveRecord::Base
    #     cache_it :first, :last
    #   end
    # 
    #   class Foo < ActiveRecord::Base
    #     cache_it do |c|
    #       c.index :first, :last
    #       c.index :email
    #       c.counters :points
    #     end
    #   end
    #
    def self.cache_it(*index)
      if self.class_variable_defined? :@@cache_it
        raise ArgumentError, "cannot reconfigure" if index.present? or block_given?
      else
        raise ArgumentError, "use block or args" if index.present? and block_given?
        config = CacheIt::Config.new self
        config.index *index if config and index.present?
        yield config if config and block_given?
        self.class_exec do
          # Returns delegate to access instance methods
          def cache_it
            @cache_it ||= CacheIt::InstanceDelegate.new self
          end
        end
        delegate = CacheIt::ClassDelegate.new self, config
        self.class_variable_set "@@cache_it", delegate
      end
      self.class_variable_get "@@cache_it"
    end
  end
end

# 
# Cache for ActiveRecord objects, backed by ActiveSupport::CacheStore of your choice.  
# 
# ==Usage
#  
#  # migration
#  create_table :users do |t|
#     t.string :first
#     t.string :last
#     t.string :email
#     t.integer :age
#     t.integer :points
#   end
#
#   class User < ActiveRecord::Base
#     cache_it do |c|
#       c.index :first, :last
#       c.index :email
#       c.counters :points
#     end
#   end
# 
#   user = User.cache_it.find(:first => "Joe", :last => "Schmoe")
#   user = User.cache_it.find(:email => "joe@example.com")
#   user.age = 30
#   user.cache_it_write
# 
module CacheIt
  class InstanceDelegate
    def initialize(base)
      @base = base
    end

    def write
      expires_in = @base.class.cache_it.config.expires_in
      val = {:attributes => @base.attributes}
      keys.each {|key| Rails.cache.write(key, val, :expires_in => expires_in)}
      stale_keys.each {|key| Rails.cache.delete(key)}
      init_counters
    end

    def increment(counter, amount = 1)
      counter = counter.to_s
      unless @base.class.cache_it.config.counters.include? counter
        raise ArgumentError, "#{counter} is not a counter"
      end
      primary_key = @base.class.primary_key
      if key = @base.class.cache_it.key({primary_key => @base[primary_key]}, :counter => counter)
        @base[counter] = Rails.cache.increment(key, amount, :raw => true)
      end
    end

    def delete
      keys(attributes_before_changes).each {|key| Rails.cache.delete(key)}
    end

    def init_counters
      primary_key = @base.class.primary_key
      @base.class.cache_it.config.counters.map do |counter|
        counter_key = @base.class.cache_it.key({primary_key => @base[primary_key]}, :counter => counter)
        @base[counter] = Rails.cache.fetch(counter_key, :raw => true) { @base[counter] }
      end
    end

    private
    def attributes_before_changes
      result = Hash.new
      @base.attributes.each do |k,v| 
        result[k] = @base.changes.include?(k) ? @base.changes[k].first : v
      end
      return result
    end

    def keys(attrs = @base.attributes)
      @base.class.cache_it.config.indexes.map do |index|
        @base.class.cache_it.key attrs.select {|attr| index.include? attr}
      end
    end

    def stale_keys
      keys(attributes_before_changes) - keys(@base.attributes)
    end
  end

  class ClassDelegate
    def initialize(base, config)
      @base = base
      @config = config
      @base.after_save Proc.new { cache_it.write }
      @base.after_destroy Proc.new { cache_it.delete }
    end

    def key(attrs, options = {})
      attrs = attrs.stringify_keys
      index = attrs.keys.sort
      raise ArgumentError, "index not available" unless @config.indexes.include? index
      if options[:counter]
        raise ArgumentError, "not a counter" unless @config.counters.include? options[:counter]
      end
      key = ["CacheIt.v1", @base.name]
      key.push options[:counter] if options[:counter]
      key.push index.map{|name| [name, attrs[name]]}.to_json
      return key.join(":")
    end

    def find(attrs, options = {})
      unless obj = read(attrs, options)
        obj = @base.where(attrs).first
        obj.cache_it.write if obj
      end
      return obj
    end

    def read(attrs, options = {})
      key = key(attrs)
      obj = nil
      if val = Rails.cache.read(key)
        attributes = val[:attributes]
        obj = @base.new
        obj.send :attributes=, attributes, false
        obj.instance_variable_set("@new_record", false) if obj.id
        obj.instance_variable_set("@changed_attributes", {}) if obj.id
        obj.cache_it.init_counters unless options[:skip_counters]
      end
      return obj
    end

    def config
      @config
    end
  end

  class Config
    def initialize(model)
      @model = model
      @indexes ||= [[@model.primary_key]]
      @counters ||= []
    end

    def index(*index)
      return nil unless index.present?
      index = index.map {|n|n.to_s}.sort
      unless index.all? {|n| @model.column_names.include? n}
        raise ArgumentError, "index must be list of column names" 
      end
      @indexes.push index unless @indexes.include? index
      validate
      return nil
    end

    def indexes
      @indexes
    end

    def counters(*counters)
      return @counters unless counters.present?
      counters = counters.map {|n|n.to_s}
      unless counters.all? {|n| @model.columns_hash[n].try(:type) == :integer}
        raise ArgumentError, "counters must be column names for integer attributes" 
      end
      counters.each do |name| 
        @counters.push name unless @counters.include? name
      end
      validate
      return nil
    end

    def expires_in(expires_in = nil, &block)
      unless expires_in or block_given?
        @expires_in.respond_to?(:call) ? @expires_in.call : @expires_in
      else
        raise ArgumentError, "use block or args" if expires_in and block_given?
        @expires_in = expires_in || block
        return nil
      end
    end

    private
    def validate
      if @indexes.flatten.any? {|name| @counters.include? name}
        raise "cannot use column for both index and counter" 
      end
    end
  end
end

