module Kiln
  module DB
    module QueryComposition
      def as(name) = Table.new(model, name, self)
      def exists = ExistsPred.new(self, false)

      def union(other, right = nil)
        right.nil? ? SetQuery.new(:union, self, other) : SetQuery.new(other, self, right)
      end

      def union_all(other) = SetQuery.new(:all, self, other)
      def intersect(other) = SetQuery.new(:intersect, self, other)
      def except(other) = SetQuery.new(:except, self, other)
    end
  end
end
