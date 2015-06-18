require_relative 'spec_helper'

describe TypedRb::Languages::PolyFeatherweightRuby::Language do
  let(:language) { described_class.new }
  let(:file) { File.join(File.dirname(__FILE__), 'examples', example) }

  context 'with valid source code' do

    let(:example) { 'counter.rb' }

    it 'should be possible to type check the code' do
      language.check_file(file)
      expect_binding(language, Counter, '@counter', Integer)
    end
  end
end
