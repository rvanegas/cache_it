module ActiveRecord
  module ModelCache
    def self.included(base)
      base.extend(ClassMethods)
    end

    def mcache_keys
      self.class.mcache_config.indexes.map do |index|
        pairs = index.map {|name| {name => self[name]}}
        self.class.mcache_key pairs.inject :merge
      end
    end

    def mcache_write
      keys = mcache_keys
      primary = keys.shift
      keys.each {|key| Rails.cache.write(key, {:primary => primary})}
      Rails.cache.write(primary, {:attributes => attributes})
    end

    def mcache_delete
      mcache_keys.each do |key|
        Rails.cache.delete(key)
      end
    end

    module ClassMethods
      def self.extended(base)
        attr_reader :mcache_config
        base.after_save :mcache_write
        base.after_destroy :mcache_delete
      end

      def mcache_key(attrs)
        attrs = attrs.stringify_keys
        index = attrs.keys.sort
        raise ArgumentError, "index not available" unless mcache_config.indexes.include? index
        key = index.map{|name| [name, attrs[name]]}
        key.push self.name
        key.push "ModelCache.v1"
        return key.to_json
      end

      def mcache_find(attrs)
        unless obj = mcache_read(attrs)
          obj = where(attrs).first
          obj.mcache_write if obj
        end
        return obj
      end

      def mcache_read(attrs)
        key = mcache_key(attrs)
        if val = Rails.cache.read(key)
          val = Rails.cache.read(val[:primary]) if val[:primary]
          attributes = val[:attributes]
          obj = new
          attributes.keys.each { |key| obj[key] = attributes[key] }
          obj.instance_variable_set("@new_record", false) if obj.id
        else
          obj = nil
        end
        return obj
      end

      private
      def mcache_init(config)
        @mcache_config = config
      end
    end

    class Config
      attr_reader :indexes

      def initialize(model)
        @model = model
      end

      def index(*index)
        return nil unless index.present?
        index = index.map{|n|n.to_s}.sort
        unless index.all?{|n| @model.column_names.include? n}
          raise ArgumentError, "index must be list of column names" 
        end
        @indexes ||= [[@model.primary_key]]
        @indexes.push index unless @indexes.include? index
        return nil
      end

      def counters(*counters)
        return @counters unless counters.present?
        counters = counters.map{|n|n.to_s}
        unless counters.all?{|n| @model.column_names.include? n}
          raise ArgumentError, "counters must be column names for integer attributes" 
        end
        @counters ||= []
        counters.each do |name| 
          @counters.push name unless @counters.include? name
        end
        return nil
      end
    end
  end

  class Base
    def self.model_cache(options = {})
      include ModelCache
      config = ModelCache::Config.new(self)
      yield config if block_given?
      config.index *options[:index] if options[:index]
      config.counters *options[:counters] if options[:counters]
      mcache_init config
    end
  end
end
