# -*- coding: utf-8 -*-
require_relative '../model'

module TypedRb
  module Languages
    module PolyFeatherweightRuby
      module Model
        # instance variable
        class TmInstanceVar < Expr

          attr_accessor :val

          def initialize(val, node)
            super(node)
            @val = val
          end

          def to_s
            "#{val}"
          end

          def rename(from_binding, to_binding)
            # instance vars cannot be captured
            self
          end

          def check_type(context)
            self_type = context.get_type_for(:self)
            type = self_type.find_var_type(val)
            fail TypeError.new("Cannot find type for variable #{val}", self) if type.nil?
            type
          end
        end
      end
    end
  end
end