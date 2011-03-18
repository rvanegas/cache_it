
require 'sqlite3'
require 'active_record'

require File.expand_path(File.dirname(__FILE__) + '/../lib/model_cache.rb')

ActiveRecord::Base.establish_connection(:adapter => 'sqlite3', :database => ":memory:")

ActiveRecord::Schema.define(:version => 1) do
  create_table :users do |t|
    t.string :name
    t.integer :points, :default => 0
  end
end

class User < ActiveRecord::Base
  model_cache :name
end

describe ActiveRecord::ModelCache do
  before do
    puts "before"
  end

  it "loads" do
    puts "loads"
    u = User.create(:name => "joe", :points => 0)
  end
end

