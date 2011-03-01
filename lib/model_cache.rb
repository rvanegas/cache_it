module ActiveRecord
  module ModelCache
    def self.included(base)
      base.extend(ClassMethods)
    end
    def mcache_keys
      self.class.mcache_indexes.map do |index|
        pairs = index.map do |name| 
          { name => self[name] }
        end
        self.class.mcache_key pairs.inject :merge
      end
    end
    def mcache_write
      mcache_keys.each do |key|
        Rails.cache.write(key, {"id" => id, "attributes" => attributes})
      end
    end
    def mcache_delete
      mcache_keys.each do |key|
        Rails.cache.delete(key)
      end
    end
    module ClassMethods
      def self.extended(base)
        attr_accessor :mcache_indexes
        base.mcache_indexes ||= [["id"]]
        base.after_save :mcache_write
        base.after_destroy :mcache_delete
      end
      def mcache_key(attrs)
        attrs = attrs.stringify_keys
        index = attrs.keys.sort
        raise ArgumentError, "index not available" unless self.mcache_indexes.include? index
        key = index.map{|name| [name, attrs[name]]}
        key << self.name
        key << "ModelCache.v1"
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
          obj = new(val["attributes"])
          obj.id = val["id"]
          obj.instance_variable_set("@new_record", false) if obj.id
        else
          obj = nil
        end
        return obj
      end
      def mcache_add_index(*index)
        return nil unless index.present?
        index = index.map{|n|n.to_s}.sort
        unless index.all?{|n|self.column_names.include? n}
          raise ArgumentError, "index must be list of column names" 
        end
        self.mcache_indexes.push index unless self.mcache_indexes.include? index
        return nil
      end
    end
  end
  class Base
    def self.model_cache(*index)
      include ModelCache
      mcache_add_index(*index)
    end
  end
end
