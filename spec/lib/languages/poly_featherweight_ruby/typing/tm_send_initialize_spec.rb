require_relative '../spec_helper'

describe TypedRb::Languages::PolyFeatherweightRuby::Model::TmSend do

  before :each do
    ::BasicObject::TypeRegistry.clear
  end

  let(:code) do
    text =<<__CODE
      class A

        ts '#initialize / Integer -> unit'
        def initialize(num)
          'String'
        end

        ts '#a / -> Integer'
        def a
          1
        end

      end

      a = A.new(3)
      A.new(a.a)
__CODE
    text
  end

  let(:typed_code) do
    $TYPECHECK = true
    eval(code, TOPLEVEL_BINDING)
    ::BasicObject::TypeRegistry.normalize_types!
    code
  end

  let(:ast) do
    TypedRb::Languages::PolyFeatherweightRuby::Model::GenSym.reset
    parser = TypedRb::Languages::PolyFeatherweightRuby::Parser.new
    parser.parse(typed_code)
  end

  context 'with validly typed code' do
    it 'should be possible to type check a method and method application' do
      type = ast.check_type(TypedRb::Languages::PolyFeatherweightRuby::Types::TypingContext.new)
      expect(type.to_s).to eq("A")
    end
  end
end
