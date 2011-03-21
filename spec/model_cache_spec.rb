
require 'ruby-debug'
Debugger.start

require 'sqlite3'
require 'active_record'
require File.expand_path(File.dirname(__FILE__) + '/../lib/model_cache.rb')


class MockCache
  def initialize
    clear
  end
  
  def write(key, val, options = {})
    @hash[key] = val
  end

  def read(key)
    @hash[key]
  end

  def fetch(key, options)
    if @hash.has_key?(key)
      @hash[key]
    elsif block_given?
      @hash[key] = yield
    end
  end

  def increment(key, amount = 1, options = {})
    @hash[key] = @hash[key].to_s.to_i + amount
  end

  def delete(key)
    @hash.delete(key)
  end

  def clear
    @hash = Hash.new
  end
end

describe MockCache do
  it "writes and reads" do
    subject.read("foo").should== nil
    subject.write("foo", 1)
    subject.read("foo").should== 1
  end

  it "fetches" do
    subject.read("foo").should== nil
    subject.fetch("foo", 1){ 1 }.should== 1
    subject.read("foo").should== 1
    subject.fetch("foo", 1).should== 1
  end

  it "increments" do
    subject.read("foo").should== nil
    subject.increment("foo")
    subject.increment("foo", 2)
    subject.write("foo", 1)
    subject.increment("foo")
    subject.increment("foo", 2)
    subject.read("foo").should== 4
  end

  it "deletes" do
    subject.read("foo").should== nil
    subject.write("foo", 1)
    subject.read("foo").should== 1
    subject.delete("foo")
    subject.read("foo").should== nil
  end
end


ActiveRecord::Base.establish_connection(:adapter => 'sqlite3', :database => ":memory:")

silence_stream(STDOUT) do
  ActiveRecord::Schema.define(:version => 1) do
    create_table :users do |t|
      t.string :code
      t.string :name
      t.integer :points, :default => 0
    end
  end
end

class Rails
  @@cache = MockCache.new
  def self.cache
    @@cache
  end
end

class User < ActiveRecord::Base
  model_cache do |c|
    c.index :code
    c.index :name
    c.counters :points
  end
end

describe ActiveRecord::ModelCache do

  context "basics with User" do

    before do
      User.delete_all
      Rails.cache.clear
      @u = User.create(:code => "x", :name => "joe")
    end

    it "reads" do
      User.mcache_read(:name => "joe").should== @u
    end

    it "writes" do
      @u.name = "jane"
      @u.mcache_write
      User.mcache_read(:name => "jane").should== @u
      User.find_by_sql("select * from users where id = #{@u.id}").first.name.should== "joe"
      @u.save!
      User.find_by_sql("select * from users where id = #{@u.id}").first.name.should== "jane"
    end

    it "increments" do
      @u.mcache_increment(:points)
      @u.points.should== 1
      User.find_by_sql("select * from users where name = 'joe'").first.points.should== 0
      @u.save!
      User.find_by_sql("select * from users where name = 'joe'").first.points.should== 1
    end

    it "deletes stale keys" do
      User.mcache_read(:code => "x").should== @u
      @u.code = "y"
      @u.save!
      User.mcache_read(:code => "x").should== nil
    end

    it "syncs counters" do
      @u.mcache_increment(:points)
      @u2 = User.mcache_read(:name => "joe")
      @u2.points.should== 1
      @u2.mcache_increment(:points)
      @u3 = User.mcache_read({:name => "joe"}, :skip_counters => true)
      @u3.points.should== 0
      @u4 = User.mcache_read(:name => "joe")
      @u4.points.should== 2
    end

    it "nil for read of unknown keys" do
      User.mcache_read(:name => "dave").should== nil
    end

    it "flags set right" do
      @u2 = User.mcache_read(:name => "joe")
      @u2.new_record?.should== false
      @u2.persisted?.should== true
    end
  end
end