require_relative "test_helper"

class LogicTypeInterpreterTest < Minitest::Test
  include TestHelper
  include FactoryHelper
  include SubtypingHelper

  include Steep

  LogicTypeInterpreter = Steep::TypeInference::LogicTypeInterpreter

  def type_env(context: nil)
    const_env = TypeInference::ConstantEnv.new(
      factory: factory,
      context: context,
      resolver: RBS::Resolver::ConstantResolver.new(builder: factory.definition_builder)
    )

    TypeInference::TypeEnv.new(const_env)
  end

  def config
    Interface::Builder::Config.new(
      resolve_self: true,
      resolve_class_type: true,
      resolve_instance_type: true,
      variable_bounds: {}
    )
  end

  def test_lvar_assignment
    with_checker do |checker|
      source = parse_ruby("a = @x")

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(source.node), parse_type("::String?"), nil)
      typing.add_typing(dig(source.node, 1), parse_type("::String?"), nil)

      env = type_env.assign_local_variable(:a, parse_type("::String?"), nil)

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, _, truthy_type, falsy_type = interpreter.eval(env: env, node: source.node)

      assert_equal parse_type("::String"), truthy_type
      assert_equal parse_type("nil"), falsy_type
      assert_equal parse_type("::String"), truthy_env[:a]
      assert_equal parse_type("nil"), falsy_env[:a]
    end
  end

  def test_masgn
    with_checker do |checker|
      source = parse_ruby("a, b = @x")

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(source.node), parse_type("[::String, ::Integer]?"), nil)
      typing.add_typing(dig(source.node, 1), parse_type("[::String, ::Integer]?"), nil)

      env =
        type_env
          .assign_local_variable(:a, parse_type("::String?"), nil)
          .assign_local_variable(:b, parse_type("::Integer?"), nil)
          .merge(instance_variable_types: { :@x => parse_type("[::String, ::Integer]?") })

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, symbols, truthy_type, falsy_type = interpreter.eval(env: env, node: source.node)

      assert_equal parse_type("[::String, ::Integer]"), truthy_type
      assert_equal parse_type("nil"), falsy_type
      assert_equal parse_type("::String"), truthy_env[:a]
      assert_equal parse_type("::Integer"), truthy_env[:b]
      assert_equal parse_type("nil"), falsy_env[:a]
      assert_equal parse_type("nil"), falsy_env[:b]
    end
  end

  def test_pure_call
    with_checker(<<-RBS) do |checker|
class Article
  attr_reader title: String

  attr_reader email: String?
end
      RBS
      source = parse_ruby("article = nil; a = article.email")

      node = source.node.children[1]

      call = TypeInference::MethodCall::Typed.new(
        node: dig(node, 1),
        context: TypeInference::MethodCall::TopLevelContext.new,
        method_name: :email,
        receiver_type: parse_type("::Article"),
        actual_method_type: parse_method_type("() -> ::String?"),
        method_decls: [],
        return_type: parse_type("::String?")
      )

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(node), parse_type("::String?"), nil)
      typing.add_typing(dig(node, 1), parse_type("::String?"), nil)
      typing.add_typing(dig(node, 1, 0), parse_type("::Article"), nil)
      typing.add_typing(dig(node, 1, 2), parse_type("::String?"), nil)

      env = type_env
        .assign_local_variable(:a, parse_type("::String?"), nil)
        .assign_local_variable(:article, parse_type("::Article"), nil)
        .add_pure_call(dig(node, 1), call, nil)

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, _, truthy_type, falsy_type = interpreter.eval(env: env, node: node)

      assert_equal parse_type("::String"), truthy_type
      assert_equal parse_type("nil"), falsy_type
      assert_equal parse_type("::String"), truthy_env[:a]
      assert_equal parse_type("nil"), falsy_env[:a]
      assert_equal parse_type("::String"), truthy_env[dig(node, 1)]
      assert_equal parse_type("nil"), falsy_env[dig(node, 1)]
    end
  end

  def test_call_is_a_p
    with_checker() do |checker|
      source = parse_ruby("email = foo; email.is_a?(String)")

      node = source.node.children[1]

      call = TypeInference::MethodCall::Typed.new(
        node: node,
        context: TypeInference::MethodCall::TopLevelContext.new,
        method_name: :is_a?,
        receiver_type: parse_type("::String?"),
        actual_method_type: parse_method_type("(::Class) -> void").yield_self do |method_type|
          method_type.with(
            type: method_type.type.with(
              return_type: AST::Types::Logic::ReceiverIsArg.new()
            )
          )
        end,
        method_decls: [],
        return_type: AST::Types::Logic::ReceiverIsArg.new()
      )

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(node), AST::Types::Logic::ReceiverIsArg.new(), nil)
      typing.add_typing(dig(node, 0), parse_type("::String?"), nil)
      typing.add_typing(dig(node, 2), parse_type("singleton(::String)"), nil)

      env = type_env
        .assign_local_variable(:email, parse_type("::String?"), nil)

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, _, truthy_type, falsy_type = interpreter.eval(env: env, node: node)

      assert_equal parse_type("true"), truthy_type
      assert_equal parse_type("false"), falsy_type
      assert_equal parse_type("::String"), truthy_env[:email]
      assert_equal parse_type("nil"), falsy_env[:email]
    end
  end

  def test_call_nil_p
    with_checker(<<-RBS) do |checker|
      RBS
      source = parse_ruby("email = foo; email.nil?")

      node = source.node.children[1]

      call = TypeInference::MethodCall::Typed.new(
        node: node,
        context: TypeInference::MethodCall::TopLevelContext.new,
        method_name: :is_a?,
        receiver_type: parse_type("::String?"),
        actual_method_type: parse_method_type("() -> bool").yield_self do |method_type|
          method_type.with(
            type: method_type.type.with(
              return_type: AST::Types::Logic::ReceiverIsNil.new()
            )
          )
        end,
        method_decls: [],
        return_type: AST::Types::Logic::ReceiverIsNil.new()
      )

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(node), AST::Types::Logic::ReceiverIsNil.new(), nil)
      typing.add_typing(dig(node, 0), parse_type("::String?"), nil)

      env = type_env
        .assign_local_variable(:email, parse_type("::String?"), nil)

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, _, truthy_type, falsy_type = interpreter.eval(env: env, node: node)

      assert_equal parse_type("true"), truthy_type
      assert_equal parse_type("false"), falsy_type
      assert_equal parse_type("nil"), truthy_env[:email]
      assert_equal parse_type("::String"), falsy_env[:email]
    end
  end

  def test_call_arg_is_receiver
    with_checker(<<-RBS) do |checker|
      RBS
      source = parse_ruby("email = foo; String === email")

      node = source.node.children[1]

      call = TypeInference::MethodCall::Typed.new(
        node: node,
        context: TypeInference::MethodCall::TopLevelContext.new,
        method_name: :is_a?,
        receiver_type: parse_type("singleton(::String)"),
        actual_method_type: parse_method_type("(untyped) -> bool").yield_self do |method_type|
          method_type.with(
            type: method_type.type.with(
              return_type: AST::Types::Logic::ArgIsReceiver.new()
            )
          )
        end,
        method_decls: [],
        return_type: AST::Types::Logic::ArgIsReceiver.new()
      )

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(node), AST::Types::Logic::ArgIsReceiver.new(), nil)
      typing.add_typing(dig(node, 0), parse_type("singleton(::String)"), nil)
      typing.add_typing(dig(node, 2), parse_type("::String?"), nil)

      env = type_env
        .assign_local_variable(:email, parse_type("::String?"), nil)

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, _, truthy_type, falsy_type = interpreter.eval(env: env, node: node)

      assert_equal parse_type("true"), truthy_type
      assert_equal parse_type("false"), falsy_type
      assert_equal parse_type("::String"), truthy_env[:email]
      assert_equal parse_type("nil"), falsy_env[:email]
    end
  end

  def test_call_arg_equals_receiver
    with_checker(<<-RBS) do |checker|
      RBS
      source = parse_ruby("email = foo; 'hello@example.com' === email")

      node = source.node.children[1]

      call = TypeInference::MethodCall::Typed.new(
        node: node,
        context: TypeInference::MethodCall::TopLevelContext.new,
        method_name: :is_a?,
        receiver_type: parse_type("::String"),
        actual_method_type: parse_method_type("(untyped) -> bool").yield_self do |method_type|
          method_type.with(
            type: method_type.type.with(
              return_type: AST::Types::Logic::ArgEqualsReceiver.new()
            )
          )
        end,
        method_decls: [],
        return_type: AST::Types::Logic::ArgEqualsReceiver.new()
      )

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(node), AST::Types::Logic::ArgEqualsReceiver.new(), nil)
      typing.add_typing(dig(node, 0), parse_type("::String"), nil)
      typing.add_typing(dig(node, 2), parse_type("::String?"), nil)

      env = type_env
        .assign_local_variable(:email, parse_type("::String?"), nil)

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, _, truthy_type, falsy_type = interpreter.eval(env: env, node: node)

      assert_equal parse_type("true"), truthy_type
      assert_equal parse_type("false"), falsy_type
      assert_equal parse_type("'hello@example.com'"), truthy_env[:email]
      assert_equal parse_type("::String | nil"), falsy_env[:email]
    end
  end

  def test_call_not
    with_checker(<<-RBS) do |checker|
      RBS

      source = parse_ruby("email = foo; !email")

      node = source.node.children[1]

      call = TypeInference::MethodCall::Typed.new(
        node: node,
        context: TypeInference::MethodCall::TopLevelContext.new,
        method_name: :is_a?,
        receiver_type: parse_type("::String?"),
        actual_method_type: parse_method_type("() -> bool").yield_self do |method_type|
          method_type.with(
            type: method_type.type.with(
              return_type: AST::Types::Logic::Not.new()
            )
          )
        end,
        method_decls: [],
        return_type: AST::Types::Logic::Not.new()
      )

      typing = Typing.new(source: source, root_context: nil)
      typing.add_typing(dig(node), AST::Types::Logic::Not.new(), nil)
      typing.add_typing(dig(node, 0), parse_type("::String?"), nil)

      env = type_env
        .assign_local_variable(:email, parse_type("::String?"), nil)

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: typing, config: config)
      truthy_env, falsy_env, _, truthy_type, falsy_type = interpreter.eval(env: env, node: node)

      assert_equal parse_type("true"), truthy_type
      assert_equal parse_type("false"), falsy_type
      assert_equal parse_type("nil"), truthy_env[:email]
      assert_equal parse_type("::String"), falsy_env[:email]
    end
  end

  def test_type_case_select
    with_checker do |checker|
      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: nil, config: config)

      assert_equal [parse_type("::String"), parse_type("bot")],
                   interpreter.type_case_select(parse_type("::String"), TypeName("::String"))

      assert_equal [parse_type("::String"), parse_type("::Integer")],
                   interpreter.type_case_select(parse_type("::String | ::Integer"), TypeName("::String"))

      assert_equal [parse_type("bot"), parse_type("::String | ::Integer")],
                   interpreter.type_case_select(parse_type("::String | ::Integer"), TypeName("::Symbol"))
    end
  end

  def test_type_case_select_untyped
    with_checker do |checker|
      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: nil, typing: nil, config: config)

      assert_equal [parse_type("::String"), parse_type("untyped")],
                   interpreter.type_case_select(parse_type("untyped"), TypeName("::String"))
    end
  end

  def test_type_case_select_top
    with_checker do |checker|
      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: nil, typing: nil, config: config)

      assert_equal [parse_type("::String"), parse_type("top")],
                   interpreter.type_case_select(parse_type("top"), TypeName("::String"))
    end
  end

  def test_type_case_select_subtype
    with_checker(<<-RBS) do |checker|
class TestParent
end

class TestChild1 < TestParent
end

class TestChild2 < TestParent
end
    RBS
      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: nil, typing: nil, config: config)

      assert_equal [parse_type("::TestChild1"), parse_type("::String")],
                   interpreter.type_case_select(parse_type("::TestChild1 | ::String"), TypeName("::TestParent"))
    end
  end

  def test_type_case_select_alias
    with_checker(<<-RBS) do |checker|
class M end
class M1 < M end
class M2 < M end
class M3 < M end
class D end
class D1 < D end
class D2 < D end

type ms = M1 | M2 | M3
type ds = D1 | D2
type dm = ms | ds
    RBS

      interpreter = LogicTypeInterpreter.new(subtyping: checker, typing: nil, typing: nil, config: config)

      assert_equal [parse_type("::M1"), parse_type("::M2 | ::M3")],
                   interpreter.type_case_select(parse_type("::ms"), TypeName("::M1"))

      assert_equal [parse_type("::M1"), parse_type("::M2 | ::M3 | ::ds")],
                   interpreter.type_case_select(parse_type("::dm"), TypeName("::M1"))

      assert_equal [parse_type("::M1 | ::M2 | ::M3"), parse_type("::ds")],
                   interpreter.type_case_select(parse_type("::dm"), TypeName("::M"))

      assert_equal [parse_type("::D2"), parse_type("::ms | ::D1")],
                   interpreter.type_case_select(parse_type("::dm"), TypeName("::D2"))
    end
  end
end
