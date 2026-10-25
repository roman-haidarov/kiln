require 'kiln/routing/router/drawing'
require 'kiln/routing/router/building'
require 'kiln/routing/router/matching'
require 'kiln/routing/router/dispatch'

module Kiln
  module Routing
    class Router
      RESOURCE_ACTIONS = { index: true, show: true, create: true, update: true, destroy: true }.freeze
      RESOURCE_ROUTES = [
        ['GET', :index, false], ['GET', :show, true], ['POST', :create, false],
        ['PUT', :update, true], ['PATCH', :update, true], ['DELETE', :destroy, true]
      ].freeze
      TRAILING_SLASH = %i[strict redirect].freeze
      EXACT_ROOT = '/'.freeze
      DOT_SEGMENTS = %w[. ..].freeze
      PERMANENT = %w[GET HEAD].freeze
      PARAM_LEADS = %w[: *].freeze
      SLASH = '/'.freeze
      HEAD = 'HEAD'.freeze
      GET = 'GET'.freeze
      UNSET = 1 << 62

      Route = Struct.new(:verb, :names, :handler, :dynamic, :glob, :seq, :limit)
      ScopeMark = Struct.new(:segments, :wrappers, :limits)
      NO_LIMIT = -1

      class Node
        attr_reader :static, :param, :glob, :routes, :first

        def initialize
          @static = {}
          @param = nil
          @glob = nil
          @routes = []
          @first = UNSET
        end

        def reach(seq)
          @first = seq if seq < @first
          self
        end

        def static_child(seg) = @static[seg] ||= Node.new

        def param_child
          @param = Node.new if @param.nil?
          @param
        end

        def glob_child
          @glob = Node.new if @glob.nil?
          @glob
        end

        def add(route)
          @routes << route
          self
        end
      end

      include Drawing
      include Building
      include Matching
      include Dispatch

      def initialize(trailing_slash: :strict)
        unless TRAILING_SLASH.include?(trailing_slash)
          raise ArgumentError, 'trailing_slash must be :strict or :redirect'
        end

        @redirect_slash = trailing_slash == :redirect
        init_tree
        init_scope
        @sealed = false
        @not_found = nil
        @not_allowed = nil
      end

      def sealed? = @sealed == true

      def call(ctx)
        req = ctx.req
        path = req.path
        return server_options(ctx) if path == '*'

        verb = req.verb
        route = fast_route(path, verb)
        return enter(route, ctx) if route

        dispatch(ctx, path, verb)
      end

      private

      def init_tree
        @root = Node.new
        @exact = {}
        @fast = {}
        @seq = 0
        @verbs = [GET].drop(1)
      end

      def init_scope
        @scope = [GET].drop(1)
        @wraps = [->(nxt) { nxt }].drop(1)
        @limits = [NO_LIMIT].drop(1)
      end
    end
  end
end
