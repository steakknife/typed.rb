# -*- coding: utf-8 -*-
require_relative '../model'

module TypedRb
  module Model
    # message send
    class TmSend < Expr
      attr_accessor :receiver, :message, :args, :block
      def initialize(receiver, message, args, node)
        super(node)
        @receiver = receiver
        @message = message
        @args = args
        @block = nil
      end

      def with_block(block)
        @block = block
      end

      def check_type(context)
        @context = context
        TypedRb.log(binding, :debug,  "Type checking message sent: #{message} at line #{node.loc.line}")
        if receiver.nil? && message == :ts
          # ignore, => type annotation
          Types::TyUnit.new(node)
        elsif message == :new && !singleton_object_type(receiver, context).nil? # clean this!
          check_instantiation(context)
        elsif receiver == :self || receiver.nil?
          # self.m(args), m(args), m
          check_type_no_explicit_receiver(context)
        else
          # x.m(args)
          check_type_explicit_receiver(context)
        end
      end

      def singleton_object_type(receiver, context)
        parsed_receiver_type = if receiver.nil? || receiver == :self
                                 context.get_type_for(:self)
                               else
                                 receiver_type
                               end
        return parsed_receiver_type if parsed_receiver_type.is_a?(Types::TySingletonObject)
      end

      # we received new, but we look for initialize in the class,
      # not the singleton class.
      # we then run the regular application,
      # but we return the class type instead of the return type
      # for the constructor application (should be unit/nil).
      def check_instantiation(context)
        self_type = singleton_object_type(receiver, context).as_object_type
        function_klass_type, function_type = self_type.find_function_type(:initialize, args.size, @block)
        TypedRb.log_dynamic_warning(node, self_type, :initialize) if function_type.dynamic?

        # function application
        @message = :initialize
        begin
          check_application(self_type, function_type, context)
        rescue TypeCheckError => error
          raise error if function_klass_type == self_type.ruby_type
        end
        self_type
      end

      def check_type_no_explicit_receiver(context)
        if message == :yield
          check_yield_application(context)
        else
          @receiver_type = context.get_type_for(:self) # check message in self type -> application
          check_type_explicit_receiver(context)
        end
      end

      def check_yield_application(context)
        yield_abs_type = context.get_type_for(:yield)
        if yield_abs_type
          check_lambda_application(yield_abs_type, context)
        else
          fail TypeCheckError.new("Error type checking message sent '#{message}': Cannot find yield function defined in typing context", node)
        end
      end

      def check_type_explicit_receiver(context)
        if receiver_type.is_a?(Types::Polymorphism::TypeVariable)
          # Existential type (Module) if receiver_type is self
          # TODO: what can we do if this is the inclusion of a module?
          arg_types = args.map { |arg| arg.check_type(context) }
          receiver_type.add_message_constraint(message, arg_types)
        elsif receiver_type.is_a?(Types::TyGenericSingletonObject) && (message == :call)
          # Application of types accept a type class or a string with a type description
          arg_types = parse_type_application_arguments(args, context)
          check_type_application_to_generic(receiver_type, arg_types)
        elsif receiver_type.is_a?(Types::TyFunction) && (message == :[] || message == :call)
          check_lambda_application(receiver_type, context)
        else
          function_klass_type, function_type = receiver_type.find_function_type(message, args.size, @block)
          TypedRb.log_dynamic_warning(node, receiver_type, message) if function_type.dynamic?
          # begin
          if function_type.nil?
            error_message = "Error type checking message sent '#{message}': Type information for #{receiver_type}:#{message} not found."
            fail TypeCheckError.new(error_message, node)
          elsif cast?(function_klass_type)
            check_casting(context)
          elsif module_include_implementation?(function_klass_type)
            check_module_inclusions(receiver_type, context)
          else
            # function application
            check_application(receiver_type, function_type, context)
          end
          # rescue TypeCheckError => error
          #  if function_klass_type != receiver_type.ruby_type
          #    Types::TyDynamic.new(Object, node)
          #  else
          #    raise error
          #  end
          # end
        end
      end

      def parse_type_application_arguments(arguments, context)
        arguments.map do |argument|
          if argument.is_a?(Model::TmString)
            type_var_signature = argument.node.children.first
            maybe_generic_method_var = Types::TypingContext.vars_info(:method)[type_var_signature]
            maybe_generic_class_var = Types::TypingContext.vars_info(:class)[type_var_signature]
            maybe_generic_module_var = Types::TypingContext.vars_info(:module)[type_var_signature]
            if maybe_generic_method_var || maybe_generic_class_var || maybe_generic_module_var
              maybe_generic_method_var || maybe_generic_class_var || maybe_generic_module_var
            else
              parsed_types = TypeSignature::Parser.parse(type_var_signature)
              if parsed_types.is_a?(Array)
                parsed_types.map { |parsed_type| parse_type_application_argument(parsed_type) }
              else
                parse_type_application_argument(parsed_types)
              end
            end
          else
            argument.check_type(context)
          end
        end.flatten
      end

      def parse_type_application_argument(type)
        # TODO: do this recursively in the case of nested generic type
        # TODO: do we need it at all?
        klass = if type.is_a?(Hash) && type[:kind] == :generic_type
                  Class.for_name(type[:type])
                end
        Runtime::TypeParser.parse(type, klass)
      end

      def type_application_counter
        @type_application_counter ||= 0
        @type_application_counter += 1
      end

      def check_type_application_to_generic(generic_type, args)
        generic_type.materialize(args)
      end

      def check_application(receiver_type, function_type, context)
        if function_type.is_a?(Types::TyDynamicFunction)
          function_type.to
        else
          if function_type.generic?
            function_type.local_typing_context.parent = Types::TypingContext.type_variables_register
            return_type = function_type.materialize do |materialized_function|
              check_application(receiver_type, materialized_function, context)
            end.to
            return_type.respond_to?(:as_object_type) ? return_type.as_object_type : return_type
          else
            formal_parameters = function_type.from
            parameters_info = function_type.parameters_info
            TypedRb.log(binding, :debug, "Checking function application #{receiver_type}::#{message}( #{parameters_info} )")
            check_args_application(parameters_info, formal_parameters, args, context)
            if @block
              block_type = @block.check_type(context)
              # TODO:
              # Unification is run here
              # Algorithm is failing:
              # G > String,
              # G < E
              # ========
              # G = [String, ?]
              # -----
              # G = [String, E]
              # E = [String, ?]
              block_return_type = if function_type.block_type
                                    # materialization and unification will happen in this invocation
                                    block_type.compatible?(function_type.block_type, :lt)
                                  else
                                    block_type.to
                                  end
              if block_return_type.to.stack_jump?
                break_type = block_return_type.to.wrapped_type.check_type(context)
                unless break_type.compatible?(function_type.to, :lt)
                  error_message = "Incompatible 'break' type, expected #{function_type.to}, found #{break_type}"
                  fail error_message, block_return_type.to.node
                end
              elsif block_return_type.to.either?
                max_type = block_return_type.check_type(context, [:return, :break, :normal])
                unless max_type.compatible?(function_type.to, :lt)
                  error_message = "Incompatible either max type, expected #{function_type.to}, found #{max_type}"
                  fail error_message, block_return_type.to.node
                end
              end
            end
            return_type = function_type.to
            return_type.respond_to?(:as_object_type) ? return_type.as_object_type : return_type
          end
        end
      end

      def check_lambda_application(lambda_type, context)
        lambda_type.check_args_application(args, context).to
      end

      def check_args_application(parameters_info, formal_parameters, actual_arguments, context)
        #binding.pry if actual_arguments.size == 1 && actual_arguments.first.class == TypedRb::Model::TmVar && actual_arguments.first.val == "klass" && actual_arguments.first.col == 36
        parameters_info.each_with_index do |(require_info, arg_name), index|
          actual_argument = actual_arguments[index]
          formal_parameter_type = formal_parameters[index]
          if formal_parameter_type.nil? && !require_info == :block
            fail TypeCheckError.new("Error type checking message sent '#{message}': Missing information about argument #{arg_name} in #{receiver}##{message}", node)
          end
          if actual_argument.nil? && require_info != :opt && require_info != :rest && require_info != :block
            fail TypeCheckError.new("Error type checking message sent '#{message}': Missing mandatory argument #{arg_name} in #{receiver}##{message}", node)
          else
            if require_info == :rest
              break if actual_argument.nil? # invocation without any of the optional arguments
              rest_type = formal_parameter_type.type_vars.first
              formal_parameter_type = if rest_type.respond_to?(:bound)
                                        rest_type.bound
                                      else
                                        rest_type
                                      end
              actual_arguments[index..-1].each do |actual_argument|
                actual_argument_type = actual_argument.check_type(context)
                unless actual_argument_type.compatible?(formal_parameter_type, :lt)
                  error_message = "Error type checking message sent '#{message}': #{formal_parameter_type} expected, #{actual_argument_type} found"
                  fail TypeCheckError.new(error_message, node)
                end
              end
              break
            else
              unless actual_argument.nil? # opt or block if this is nil
                actual_argument_type = actual_argument.check_type(context)
                fail TypeCheckError.new("Error type checking message sent '#{message}': Missing type information for argument '#{arg_name}'", node) if formal_parameter_type.nil?
                begin
                  unless actual_argument_type.compatible?(formal_parameter_type, :lt)
                    error_message = "Error type checking message sent '#{message}': #{formal_parameter_type} expected, #{actual_argument_type} found"
                    fail TypeCheckError.new(error_message, node)
                  end
                rescue Types::UncomparableTypes, ArgumentError
                  raise Types::UncomparableTypes.new(actual_argument_type, formal_parameter_type, node)
                end
              end
            end
          end
        end
      end

      def cast?(function_klass_type)
        function_klass_type == BasicObject && message == :cast
      end

      def check_casting(context)
        from_type = args[0].check_type(context)
        to = parse_type_application_arguments([args[1]], context).first
        to_type = to.is_a?(Types::TyObject) ? to.as_object_type : to
        TypedRb.log(binding, :info, "Casting #{from_type} into #{to_type}")
        to_type
      end

      def module_include_implementation?(function_klass_type)
        function_klass_type == Module && message == :include
      end

      def check_module_inclusions(self_type, context)
        args.map do |arg|
          arg.check_type(context)
        end.each do |module_type|
          if module_type.is_a?(Types::TyExistentialType)
            if module_type.local_typing_context
              module_type.check_inclusion(self_type)
            else
              # TODO: report warning about missing module information
              TypedRb.log(binding, :debug,  "Not type checking module #{module_type.ruby_type} inclusion due to lack of module information")
            end
          else
            error_message = "Error type checking message sent '#{message}': Module type expected for inclusion in #{self_type}, #{module_type} found"
            fail TypeCheckError.new(error_message, node)
          end
        end
        self_type
      end

      def receiver_type
        @receiver_type ||= receiver.check_type(@context)
      end
    end
  end
end
