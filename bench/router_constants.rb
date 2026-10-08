require "set"
require "kiln"

actions = [:index, :show, :create, :update, :destroy].freeze
action_set = Set.new(actions).freeze
action_hash = { index: true, show: true, create: true, update: true, destroy: true }.freeze
routes = [
  ["GET", :index, false], ["GET", :show, true], ["POST", :create, false],
  ["PUT", :update, true], ["PATCH", :update, true], ["DELETE", :destroy, true]
].freeze
route_set = Set.new(routes).freeze
mode = ARGV[0] || "array"
seconds = (ARGV[1] || "10").to_f
deadline = Kiln.now + seconds
iterations = 0
matches = 0

while Kiln.now < deadline
  batch = 0
  while batch < 10_000
    if mode == "array"
      actions.each { |action| matches += 1 if actions.include?(action) }
      routes.each { |route| matches += 1 if actions.include?(route[1]) }
    elsif mode == "set"
      actions.each { |action| matches += 1 if action_set.include?(action) }
      routes.each { |route| matches += 1 if action_set.include?(route[1]) }
    elsif mode == "hash"
      actions.each { |action| matches += 1 if action_hash.key?(action) }
      routes.each { |route| matches += 1 if action_hash.key?(route[1]) }
    elsif mode == "route_array"
      routes.each { |route| matches += 1 if route[2] }
    elsif mode == "route_set"
      route_set.each { |route| matches += 1 if route[2] }
    else
      raise ArgumentError, "mode"
    end
    iterations += 1
    batch += 1
  end
end

puts "mode=#{mode} seconds=#{seconds} batches=#{iterations} matches=#{matches}"
