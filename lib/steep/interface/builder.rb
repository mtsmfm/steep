module Steep
  module Interface
    class Builder
      class Config
        attr_reader :self_type, :class_type, :instance_type, :variable_bounds

        def initialize(self_type:, class_type: nil, instance_type: nil, variable_bounds:)
          @self_type = self_type
          @class_type = class_type
          @instance_type = instance_type
          @variable_bounds = variable_bounds

          validate
        end

        def self.empty
          new(self_type: nil, variable_bounds: {})
        end

        def subst
          if self_type || class_type || instance_type
            Substitution.build([], [], self_type: self_type, module_type: class_type, instance_type: instance_type)
          end
        end

        def validate
          validate_fvs(:self_type, self_type)
          validate_fvs(:instance_type, instance_type)
          validate_fvs(:class_type, class_type)
          self
        end

        def validate_fvs(name, type)
          if type
            fvs = type.free_variables
            if fvs.include?(AST::Types::Self.instance)
              raise "#{name} cannot include 'self' type: #{type}"
            end
            if fvs.include?(AST::Types::Instance.instance)
              raise "#{name} cannot include 'instance' type: #{type}"
            end
            if fvs.include?(AST::Types::Class.instance)
              raise "#{name} cannot include 'class' type: #{type}"
            end
          end
        end

        def upper_bound(a)
          variable_bounds.fetch(a, nil)
        end
      end

      attr_reader :factory, :object_shape_cache, :union_shape_cache, :singleton_shape_cache

      def initialize(factory)
        @factory = factory
        @object_shape_cache = {}
        @union_shape_cache = {}
        @singleton_shape_cache = {}
      end

      def shape(type, config)
        Steep.logger.tagged "shape(#{type})" do
          if shape = raw_shape(type, config)
            # Optimization that skips unnecesary substittuion
            if type.free_variables.include?(AST::Types::Self.instance)
              shape
            else
              if s = config.subst
                shape.subst(s)
              else
                shape
              end
            end
          end
        end
      end

      def fetch_cache(cache, key)
        if cache.key?(key)
          return cache.fetch(key)
        end

        cache[key] = yield
      end

      def raw_shape(type, config)
        case type
        when AST::Types::Self
          self_type = config.self_type or raise
          self_shape(self_type, config)
        when AST::Types::Instance
          instance_type = config.instance_type or raise
          raw_shape(instance_type, config)
        when AST::Types::Class
          klass_type = config.class_type or raise
          raw_shape(klass_type, config)
        when AST::Types::Name::Singleton
          singleton_shape(type.name).subst(class_subst(type))
        when AST::Types::Name::Instance
          object_shape(type.name).subst(class_subst(type).merge(app_subst(type)), type: type)
        when AST::Types::Name::Interface
          object_shape(type.name).subst(interface_subst(type).merge(app_subst(type)), type: type)
        when AST::Types::Union
          groups = type.types.group_by do |type|
            if type.is_a?(AST::Types::Literal)
              type.back_type
            else
              nil
            end
          end

          shapes = [] #: Array[Shape]
          groups.each do |name, types|
            if name
              union = AST::Types::Union.build(types: types)
              subst = class_subst(name).update(self_type: union)
              shapes << object_shape(name.name).subst(subst, type: union)
            else
              shapes.concat(types.map {|ty| raw_shape(ty, config) or return })
            end
          end

          fetch_cache(union_shape_cache, type) do
            union_shape(type, shapes)
          end
        when AST::Types::Intersection
          shapes = type.types.map do |type|
            raw_shape(type, config) or return
          end
          intersection_shape(type, shapes)
        when AST::Types::Name::Alias
          expanded = factory.expand_alias(type)
          if shape = raw_shape(expanded, config)
            shape.update(type: type)
          end
        when AST::Types::Literal
          instance_type = type.back_type
          subst = class_subst(instance_type).update(self_type: type)
          object_shape(instance_type.name).subst(subst, type: type)
        when AST::Types::Boolean
          true_shape =
            (object_shape(RBS::BuiltinNames::TrueClass.name)).
              subst(class_subst(AST::Builtin::TrueClass.instance_type).update(self_type: type))
          false_shape =
            (object_shape(RBS::BuiltinNames::FalseClass.name)).
              subst(class_subst(AST::Builtin::FalseClass.instance_type).update(self_type: type))
          union_shape(type, [true_shape, false_shape])
        when AST::Types::Proc
          shape = object_shape(AST::Builtin::Proc.module_name).subst(class_subst(AST::Builtin::Proc.instance_type).update(self_type: type))
          proc_shape(type, shape)
        when AST::Types::Tuple
          tuple_shape(type) do |array|
            object_shape(array.name).subst(
              class_subst(array).update(self_type: type).merge(app_subst(array))
            )
          end
        when AST::Types::Record
          record_shape(type) do |hash|
            object_shape(hash.name).subst(
              class_subst(hash).update(self_type: type).merge(app_subst(hash))
            )
          end
        when AST::Types::Var
          if bound = config.upper_bound(type.name)
            new_config = Config.new(self_type: bound, variable_bounds: config.variable_bounds)
            sub = Substitution.build([], self_type: type)
            # We have to use `self_shape` insead of `raw_shape` here.
            # Keep the `self` types included in the `bound`'s shape, and replace it to the type variable.
            self_shape(bound, new_config)&.subst(sub, type: type)
          end
        when AST::Types::Nil
          subst = class_subst(AST::Builtin::NilClass.instance_type).update(self_type: type)
          object_shape(AST::Builtin::NilClass.module_name).subst(subst, type: type)
        when AST::Types::Logic::Base
          true_shape =
            (object_shape(RBS::BuiltinNames::TrueClass.name)).
              subst(class_subst(AST::Builtin::TrueClass.instance_type).update(self_type: type))
          false_shape =
            (object_shape(RBS::BuiltinNames::FalseClass.name)).
              subst(class_subst(AST::Builtin::FalseClass.instance_type).update(self_type: type))
          union_shape(type, [true_shape, false_shape])
        else
          nil
        end
      end

      def self_shape(type, config)
        case type
        when AST::Types::Self, AST::Types::Instance, AST::Types::Class
          raise
        when AST::Types::Name::Singleton
          singleton_shape(type.name).subst(class_subst(type).update(self_type: nil))
        when AST::Types::Name::Instance
          object_shape(type.name)
            .subst(
              class_subst(type).update(self_type: nil).merge(app_subst(type)),
              type: type
            )
        when AST::Types::Name::Interface
          object_shape(type.name).subst(app_subst(type), type: type)
        when AST::Types::Literal
          instance_type = type.back_type
          subst = class_subst(instance_type).update(self_type: nil)
          object_shape(instance_type.name).subst(subst, type: type)
        when AST::Types::Boolean
          true_shape =
            (object_shape(RBS::BuiltinNames::TrueClass.name)).
              subst(class_subst(AST::Builtin::TrueClass.instance_type).update(self_type: nil))
          false_shape =
            (object_shape(RBS::BuiltinNames::FalseClass.name)).
              subst(class_subst(AST::Builtin::FalseClass.instance_type).update(self_type: nil))
          union_shape(type, [true_shape, false_shape])
        when AST::Types::Proc
          shape = object_shape(AST::Builtin::Proc.module_name).subst(class_subst(AST::Builtin::Proc.instance_type).update(self_type: nil))
          proc_shape(type, shape)
        when AST::Types::Var
          if bound = config.upper_bound(type.name)
            self_shape(bound, config)&.update(type: type)
          end
        else
          raw_shape(type, config)
        end
      end

      def app_subst(type)
        if type.args.empty?
          return Substitution.empty
        end

        vars =
          case type
          when AST::Types::Name::Instance
            entry = factory.env.normalized_module_class_entry(type.name) or raise
            entry.primary.decl.type_params.map { _1.name }
          when AST::Types::Name::Interface
            entry = factory.env.interface_decls.fetch(type.name)
            entry.decl.type_params.map { _1.name }
          when AST::Types::Name::Alias
            entry = factory.env.type_alias_decls.fetch(type.name)
            entry.decl.type_params.map { _1.name }
          end

        Substitution.build(vars, type.args)
      end

      def class_subst(type)
        case type
        when AST::Types::Name::Singleton
          self_type = type
          singleton_type = type
          instance_type = factory.instance_type(type.name)
        when AST::Types::Name::Instance
          self_type = type
          singleton_type = type.to_module
          instance_type = factory.instance_type(type.name)
        end

        Substitution.build([], self_type: self_type, module_type: singleton_type, instance_type: instance_type)
      end

      def interface_subst(type)
        Substitution.build([], self_type: type)
      end

      def singleton_shape(type_name)
        singleton_shape_cache[type_name] ||= begin
          shape = Interface::Shape.new(type: AST::Types::Name::Singleton.new(name: type_name), private: true)
          definition = factory.definition_builder.build_singleton(type_name)

          definition.methods.each do |name, method|
            Steep.logger.tagged "method = #{type_name}.#{name}" do
              shape.methods[name] = Interface::Shape::Entry.new(
                private_method: method.private?,
                method_types: method.defs.map do |type_def|
                  method_name = method_name_for(type_def, name)
                  decl = TypeInference::MethodCall::MethodDecl.new(method_name: method_name, method_def: type_def)
                  method_type = factory.method_type(type_def.type, method_decls: Set[decl])
                  replace_primitive_method(method_name, type_def, method_type)
                end
              )
            end
          end

          shape
        end
      end

      def object_shape(type_name)
        object_shape_cache[type_name] ||= begin
          shape = Interface::Shape.new(type: AST::Builtin.bottom_type, private: true)

          case
          when type_name.class?
            definition = factory.definition_builder.build_instance(type_name)
          when type_name.interface?
            definition = factory.definition_builder.build_interface(type_name)
          end

          definition or raise

          definition.methods.each do |name, method|
            Steep.logger.tagged "method = #{type_name}##{name}" do
              shape.methods[name] = Interface::Shape::Entry.new(
                private_method: method.private?,
                method_types: method.defs.map do |type_def|
                  method_name = method_name_for(type_def, name)
                  decl = TypeInference::MethodCall::MethodDecl.new(method_name: method_name, method_def: type_def)
                  method_type = factory.method_type(type_def.type, method_decls: Set[decl])
                  replace_primitive_method(method_name, type_def, method_type)
                end
              )
            end
          end

          shape
        end
      end

      def union_shape(shape_type, shapes)
        s0, *sx = shapes
        s0 or raise
        all_common_methods = Set.new(s0.methods.each_name)
        sx.each do |shape|
          all_common_methods &= shape.methods.each_name
        end

        shape = Interface::Shape.new(type: shape_type, private: true)
        all_common_methods.each do |method_name|
          method_typess = [] #: Array[Array[MethodType]]
          private_method = false
          shapes.each do |shape|
            entry = shape.methods[method_name] || raise
            method_typess << entry.method_types
            private_method ||= entry.private_method?
          end

          shape.methods[method_name] = Interface::Shape::Entry.new(private_method: private_method) do
            method_typess.inject do |types1, types2|
              # @type break: nil

              if types1 == types2
                decl_array1 = types1.map(&:method_decls)
                decl_array2 = types2.map(&:method_decls)

                if decl_array1 == decl_array2
                  next types1
                end

                decls1 = decl_array1.each.with_object(Set[]) {|array, decls| decls.merge(array) } #$ Set[TypeInference::MethodCall::MethodDecl]
                decls2 = decl_array2.each.with_object(Set[]) {|array, decls| decls.merge(array) } #$ Set[TypeInference::MethodCall::MethodDecl]

                if decls1 == decls2
                  next types1
                end
              end

              method_types = {} #: Hash[MethodType, bool]

              types1.each do |type1|
                types2.each do |type2|
                  if type1 == type2
                    method_types[type1.with(method_decls: type1.method_decls + type2.method_decls)] = true
                  else
                    if type = MethodType.union(type1, type2, subtyping)
                      method_types[type] = true
                    end
                  end
                end
              end

              break nil if method_types.empty?

              method_types.keys
            end
          end
        end

        shape
      end

      def intersection_shape(type, shapes)
        shape = Interface::Shape.new(type: type, private: true)

        shapes.each do |s|
          shape.methods.merge!(s.methods) do |name, old_entry, new_entry|
            if old_entry.public_method? && new_entry.private_method?
              old_entry
            else
              new_entry
            end
          end
        end

        shape
      end

      def method_name_for(type_def, name)
        type_name = type_def.implemented_in || type_def.defined_in

        if name == :new && type_def.member.is_a?(RBS::AST::Members::MethodDefinition) && type_def.member.name == :initialize
          return SingletonMethodName.new(type_name: type_name, method_name: name)
        end

        case type_def.member.kind
        when :instance
          InstanceMethodName.new(type_name: type_name, method_name: name)
        when :singleton
          SingletonMethodName.new(type_name: type_name, method_name: name)
        when :singleton_instance
          # Assume it a instance method, because `module_function` methods are typically defined with `def`
          InstanceMethodName.new(type_name: type_name, method_name: name)
        else
          raise
        end
      end

      def subtyping
        @subtyping ||= Subtyping::Check.new(builder: self)
      end

      def tuple_shape(tuple)
        element_type = AST::Types::Union.build(types: tuple.types, location: nil)
        array_type = AST::Builtin::Array.instance_type(element_type)

        array_shape = yield(array_type) or raise
        shape = Shape.new(type: tuple, private: true)
        shape.methods.merge!(array_shape.methods)

        aref_entry = array_shape.methods[:[]].yield_self do |aref|
          raise unless aref

          Shape::Entry.new(
            private_method: false,
            method_types: tuple.types.map.with_index {|elem_type, index|
              MethodType.new(
                type_params: [],
                type: Function.new(
                  params: Function::Params.build(required: [AST::Types::Literal.new(value: index)]),
                  return_type: elem_type,
                  location: nil
                ),
                block: nil,
                method_decls: Set[]
              )
            } + aref.method_types
          )
        end

        aref_update_entry = array_shape.methods[:[]=].yield_self do |update|
          raise unless update

          Shape::Entry.new(
            private_method: false,
            method_types: tuple.types.map.with_index {|elem_type, index|
              MethodType.new(
                type_params: [],
                type: Function.new(
                  params: Function::Params.build(required: [AST::Types::Literal.new(value: index), elem_type]),
                  return_type: elem_type,
                  location: nil
                ),
                block: nil,
                method_decls: Set[]
              )
            } + update.method_types
          )
        end

        fetch_entry = array_shape.methods[:fetch].yield_self do |fetch|
          raise unless fetch

          Shape::Entry.new(
            private_method: false,
            method_types: tuple.types.flat_map.with_index {|elem_type, index|
              [
                MethodType.new(
                  type_params: [],
                  type: Function.new(
                    params: Function::Params.build(required: [AST::Types::Literal.new(value: index)]),
                    return_type: elem_type,
                    location: nil
                  ),
                  block: nil,
                  method_decls: Set[]
                ),
                MethodType.new(
                  type_params: [TypeParam.new(name: :T, upper_bound: nil, variance: :invariant, unchecked: false)],
                  type: Function.new(
                    params: Function::Params.build(
                      required: [
                        AST::Types::Literal.new(value: index),
                        AST::Types::Var.new(name: :T)
                      ]
                    ),
                    return_type: AST::Types::Union.build(types: [elem_type, AST::Types::Var.new(name: :T)]),
                    location: nil
                  ),
                  block: nil,
                  method_decls: Set[]
                ),
                MethodType.new(
                  type_params: [TypeParam.new(name: :T, upper_bound: nil, variance: :invariant, unchecked: false)],
                  type: Function.new(
                    params: Function::Params.build(required: [AST::Types::Literal.new(value: index)]),
                    return_type: AST::Types::Union.build(types: [elem_type, AST::Types::Var.new(name: :T)]),
                    location: nil
                  ),
                  block: Block.new(
                    type: Function.new(
                      params: Function::Params.build(required: [AST::Builtin::Integer.instance_type]),
                      return_type: AST::Types::Var.new(name: :T),
                      location: nil
                    ),
                    optional: false,
                    self_type: nil
                  ),
                  method_decls: Set[]
                )
              ]
            } + fetch.method_types
          )
        end

        first_entry = array_shape.methods[:first].yield_self do |first|
          Shape::Entry.new(
            private_method: false,
            method_types: [
              MethodType.new(
                type_params: [],
                type: Function.new(
                  params: Function::Params.empty,
                  return_type: tuple.types[0] || AST::Builtin.nil_type,
                  location: nil
                ),
                block: nil,
                method_decls: Set[]
              )
            ]
          )
        end

        last_entry = array_shape.methods[:last].yield_self do |last|
          Shape::Entry.new(
            private_method: false,
            method_types: [
              MethodType.new(
                type_params: [],
                type: Function.new(
                  params: Function::Params.empty,
                  return_type: tuple.types.last || AST::Builtin.nil_type,
                  location: nil
                ),
                block: nil,
                method_decls: Set[]
              )
            ]
          )
        end

        shape.methods[:[]] = aref_entry
        shape.methods[:[]=] = aref_update_entry
        shape.methods[:fetch] = fetch_entry
        shape.methods[:first] = first_entry
        shape.methods[:last] = last_entry

        shape
      end

      def record_shape(record)
        all_key_type = AST::Types::Union.build(
          types: record.elements.each_key.map {|value| AST::Types::Literal.new(value: value, location: nil) },
          location: nil
        )
        all_value_type = AST::Types::Union.build(types: record.elements.values, location: nil)
        hash_type = AST::Builtin::Hash.instance_type(all_key_type, all_value_type)

        hash_shape = yield(hash_type) or raise
        shape = Shape.new(type: record, private: true)
        shape.methods.merge!(hash_shape.methods)

        shape.methods[:[]] = hash_shape.methods[:[]].yield_self do |aref|
          aref or raise
          Shape::Entry.new(
            private_method: false,
            method_types: record.elements.map do |key_value, value_type|
              key_type = AST::Types::Literal.new(value: key_value, location: nil)

              MethodType.new(
                type_params: [],
                type: Function.new(
                  params: Function::Params.build(required: [key_type]),
                  return_type: value_type,
                  location: nil
                ),
                block: nil,
                method_decls: Set[]
              )
            end + aref.method_types
          )
        end

        shape.methods[:[]=] = hash_shape.methods[:[]=].yield_self do |update|
          update or raise

          Shape::Entry.new(
            private_method: false,
            method_types: record.elements.map do |key_value, value_type|
              key_type = AST::Types::Literal.new(value: key_value, location: nil)
              MethodType.new(
                type_params: [],
                type: Function.new(
                  params: Function::Params.build(required: [key_type, value_type]),
                  return_type: value_type,
                  location: nil),
                block: nil,
                method_decls: Set[]
              )
            end + update.method_types
          )
        end

        shape.methods[:fetch] = hash_shape.methods[:fetch].yield_self do |update|
          update or raise

          Shape::Entry.new(
            private_method: false,
            method_types: record.elements.flat_map {|key_value, value_type|
              key_type = AST::Types::Literal.new(value: key_value, location: nil)

              [
                MethodType.new(
                  type_params: [],
                  type: Function.new(
                    params: Function::Params.build(required: [key_type]),
                    return_type: value_type,
                    location: nil
                  ),
                  block: nil,
                  method_decls: Set[]
                ),
                MethodType.new(
                  type_params: [TypeParam.new(name: :T, upper_bound: nil, variance: :invariant, unchecked: false)],
                  type: Function.new(
                    params: Function::Params.build(required: [key_type, AST::Types::Var.new(name: :T)]),
                    return_type: AST::Types::Union.build(types: [value_type, AST::Types::Var.new(name: :T)]),
                    location: nil
                  ),
                  block: nil,
                  method_decls: Set[]
                ),
                MethodType.new(
                  type_params: [TypeParam.new(name: :T, upper_bound: nil, variance: :invariant, unchecked: false)],
                  type: Function.new(
                    params: Function::Params.build(required: [key_type]),
                    return_type: AST::Types::Union.build(types: [value_type, AST::Types::Var.new(name: :T)]),
                    location: nil
                  ),
                  block: Block.new(
                    type: Function.new(
                      params: Function::Params.build(required: [all_key_type]),
                      return_type: AST::Types::Var.new(name: :T),
                      location: nil
                    ),
                    optional: false,
                    self_type: nil
                  ),
                  method_decls: Set[]
                )
              ]
            } + update.method_types
          )
        end

        shape
      end

      def proc_shape(proc, proc_shape)
        shape = Shape.new(type: proc, private: true)
        shape.methods.merge!(proc_shape.methods)

        shape.methods[:[]] = shape.methods[:call] = Shape::Entry.new(
          private_method: false,
          method_types: [MethodType.new(type_params: [], type: proc.type, block: proc.block, method_decls: Set[])]
        )

        shape
      end

      def replace_primitive_method(method_name, method_def, method_type)
        defined_in = method_def.defined_in
        member = method_def.member

        if member.is_a?(RBS::AST::Members::MethodDefinition)
          case method_name.method_name
          when :is_a?, :kind_of?, :instance_of?
            case
            when RBS::BuiltinNames::Object.name,
              RBS::BuiltinNames::Kernel.name
              if member.instance?
                return method_type.with(
                  type: method_type.type.with(
                    return_type: AST::Types::Logic::ReceiverIsArg.new(location: method_type.type.return_type.location)
                  )
                )
              end
            end

          when :nil?
            case defined_in
            when RBS::BuiltinNames::Object.name,
              AST::Builtin::NilClass.module_name,
              RBS::BuiltinNames::Kernel.name
              if member.instance?
                return method_type.with(
                  type: method_type.type.with(
                    return_type: AST::Types::Logic::ReceiverIsNil.new(location: method_type.type.return_type.location)
                  )
                )
            end
            end

          when :present?
            case defined_in
            when RBS::BuiltinNames::Object.name,
              AST::Builtin::NilClass.module_name,
              RBS::BuiltinNames::Kernel.name
              if member.instance?
                return method_type.with(
                  type: method_type.type.with(
                    return_type: AST::Types::Logic::ReceiverIsNotNil.new(location: method_type.type.return_type.location)
                  )
                )
            end
            end

          when :!
            case defined_in
            when RBS::BuiltinNames::BasicObject.name,
              RBS::BuiltinNames::TrueClass.name,
              RBS::BuiltinNames::FalseClass.name,
              AST::Builtin::NilClass.module_name
              return method_type.with(
                type: method_type.type.with(
                  return_type: AST::Types::Logic::Not.new(location: method_type.type.return_type.location)
                )
              )
            end

          when :===
            case defined_in
            when RBS::BuiltinNames::Module.name
              return method_type.with(
                type: method_type.type.with(
                  return_type: AST::Types::Logic::ArgIsReceiver.new(location: method_type.type.return_type.location)
                )
              )
            when RBS::BuiltinNames::Object.name,
              RBS::BuiltinNames::Kernel.name,
              RBS::BuiltinNames::String.name,
              RBS::BuiltinNames::Integer.name,
              RBS::BuiltinNames::Symbol.name,
              RBS::BuiltinNames::TrueClass.name,
              RBS::BuiltinNames::FalseClass.name,
              TypeName("::NilClass")
              # Value based type-case works on literal types which is available for String, Integer, Symbol, TrueClass, FalseClass, and NilClass
              return method_type.with(
                type: method_type.type.with(
                  return_type: AST::Types::Logic::ArgEqualsReceiver.new(location: method_type.type.return_type.location)
                )
              )
            end
          when :<, :<=
            case defined_in
            when RBS::BuiltinNames::Module.name
              return method_type.with(
                type: method_type.type.with(
                  return_type: AST::Types::Logic::ArgIsAncestor.new(location: method_type.type.return_type.location)
                )
              )
            end
          end
        end

        method_type
      end
    end
  end
end

