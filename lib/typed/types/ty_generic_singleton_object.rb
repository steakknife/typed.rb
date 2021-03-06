require_relative 'ty_singleton_object'
require_relative 'polymorphism/generic_comparisons'
require_relative 'polymorphism/generic_variables'
require_relative 'polymorphism/generic_object'
require_relative 'singleton_object'

module TypedRb
  module Types
    class TyGenericSingletonObject < TySingletonObject
      include Polymorphism::GenericObject
      include Polymorphism::GenericComparisons
      include Polymorphism::GenericVariables
      include SingletonObject

      attr_accessor :local_typing_context, :super_type

      def initialize(ruby_type, type_vars, super_type = nil, node = nil)
        super(ruby_type, node)
        @super_type = super_type
        @type_vars = type_vars
        @application_count = 0
      end

      def materialize_with_type_vars(type_vars, bound_type)
        TypedRb.log binding, :debug, "Materialising generic singleton object with type vars '#{self}' <= #{type_vars.map(&:to_s).join(',')} :: #{bound_type}"
        bound_type_vars = self.type_vars.map do |type_var|
          maybe_class_bound = type_vars.detect do |bound_type_var|
            type_var.variable == bound_type_var.variable
          end
          if maybe_class_bound.nil?
            # it has to be method generic variable
            type_var
          else
            maybe_class_bound
          end
        end
        materialize(bound_type_vars.map { |bound_type_var| bound_type_var.send(bound_type) })
      end

      def self_materialize
        TypedRb.log binding, :debug, "Materialising self for generic singleton object '#{self}'"
        generic_type = BasicObject::TypeRegistry.find_generic_type(ruby_type)
        fail TypeCheckError.new("Missing generic type annotation for #{ruby_type}", node) if generic_type.nil?
        generic_type.materialize(type_vars)
      end

      # materialize will be invoked by the logic handling invocations like:
      # ts 'MyClass[X][Y]'
      # class MyClass
      #  ...
      # end
      # MyClass.(TypeArg1, TypeArg2)  -> make X<TypeArg1, Y<TypeArg2, X>TypeArg1, X>TypeArg2
      # MyClass.(TypeArg1, TypeArg2)  -> Materialize here > make X<TypeArg1, Y<TypeArg2 > Unification
      def materialize(actual_arguments)
        TypedRb.log binding, :debug, "Materialising generic singleton object '#{self}' with args [#{actual_arguments.map(&:to_s).join(',')}]"
        # This can happen when we're dealing with a generic singleton object that has only been
        # annotated but we don't have the annotated implementation. e.g. Array[T]
        # We need to provide a default local_type_context based on the upper bounds provided in the
        # type annotation.
        compute_minimal_typing_context if @local_typing_context.nil?

        applied_typing_context, substitutions = @local_typing_context.clone(:class)
        fresh_vars_generic_type = clone_with_substitutions(substitutions)
        TypingContext.with_context(applied_typing_context) do
          # Appy constraints for application of Type args
          apply_type_arguments(fresh_vars_generic_type, actual_arguments)
        end
        # got all the constraints here
        # do something with the context -> unification? merge context?
        # applied_typing_context.all_constraints.each{|(l,t,r)| puts "#{l} #{t} #{r}" }
        unification = Polymorphism::Unification.new(applied_typing_context.all_constraints).run
        applied_typing_context.unlink # these constraints have already been satisfied
        # - Create a new ty_generic_object for the  unified types
        # - Apply the unified types to all the methods in the class/instance
        #   - this can be dynamically done with the right implementation of find_function_type
        # - Make the class available for the type checking system, so it can be found when
        #   - this can be done, just returning the new ty_singleton_object with the unified types
        #   - messages will be redirected to that instance and find_function_type/ find_var_type / as_object
        #     will handle the mesage
        # - looking for messages at the instance level
        #   - this can be accomplished with the overloading version of as_object_type, that will return
        #     an instance of a new class ty_generic_object with overloaded versions of find_function_type /find_var_type
        ########################
        fresh_vars_generic_type.apply_bindings(unification.bindings_map)
      end

      def as_object_type
        # this should only be used to check the body type of this
        # class. The variables are going to be unbound.
        # This is also used in instantiation of the generic object.
        TyGenericObject.new(ruby_type, @type_vars)
      end

      def compute_minimal_typing_context
        Model::TmClass.with_fresh_bindings(self, nil, node)
      end

      def apply_bindings(bindings_map)
        type_vars(recursive: false).each_with_index do |var, _i|
          if var.is_a?(Polymorphism::TypeVariable) && var.bound_to_generic?
            var.bind(var.bound.apply_bindings(bindings_map))
          elsif var.is_a?(Polymorphism::TypeVariable)
            var.apply_bindings(bindings_map)
          elsif var.is_a?(TyGenericSingletonObject) || var.is_a?(TyGenericObject)
            var.apply_bindings(bindings_map)
          end
        end
        self
      end

      def clone
        cloned_type_vars = type_vars.map(&:clone)
        TyGenericSingletonObject.new(ruby_type, cloned_type_vars, super_type, node)
      end

      # This object has concrete type parameters
      # The generic Function we retrieve from the registry might be generic
      # If it is generic we apply the bound parameters and we obtain a concrete function type
      def find_function_type(message, num_args, block)
        function_klass_type, function_type = super(message, num_args, block)
        if function_klass_type != ruby_type && ancestor_of_super_type?(generic_singleton_object.super_type, function_klass_type)
          target_class = ancestor_of_super_type?(generic_singleton_object.super_type, function_klass_type)
          TypedRb.log binding, :debug, "Found message '#{message}', generic function: #{function_type}, explicit super type #{target_class}"
          target_type_vars = target_class.type_vars
          materialize_super_type_found_function(message, num_args, block, target_class, target_type_vars)
        elsif function_klass_type != ruby_type && BasicObject::TypeRegistry.find_generic_type(function_klass_type)
          TypedRb.log binding, :debug, "Found message '#{message}', generic function: #{function_type}, implict super type #{function_klass_type}"
          target_class = BasicObject::TypeRegistry.find_generic_type(function_klass_type)
          materialize_super_type_found_function(message, num_args, block, target_class, type_vars)
        else
          TypedRb.log binding, :debug, "Found message '#{message}', generic function: #{function_type}"
          materialized_function = materialize_found_function(function_type)
          TypedRb.log binding, :debug, "Found message '#{message}', materialized generic function: #{materialized_function}"
          [function_klass_type, materialized_function]
        end
      end

    end
  end
end
