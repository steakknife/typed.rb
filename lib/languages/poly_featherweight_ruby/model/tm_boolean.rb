# -*- coding: utf-8 -*-
require_relative '../model'

module TypedRb
  module Languages
    module PolyFeatherweightRuby
      module Model
        # booleans
        class TmBoolean < Expr
          attr_accessor :val
          def initialize(node)
            super(node, Types::TyBoolean.new)
            @val = node.type == 'true' ? true : false
          end

          def to_s
            if @val
              'True'
            else
              'False'
            end
          end
        end
      end
    end
  end
end
