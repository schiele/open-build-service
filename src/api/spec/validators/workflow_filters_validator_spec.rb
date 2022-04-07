require 'rails_helper'

RSpec.describe WorkflowFiltersValidator do
  let(:fake_model) do
    Struct.new(:workflow_instructions) do
      include ActiveModel::Validations

      # To prevent the error "ArgumentError: Class name cannot be blank. You need to supply a name argument when anonymous class given"
      def self.name
        'FakeModel'
      end

      validates_with WorkflowFiltersValidator
    end
  end

  describe '#validate' do
    subject { fake_model.new(workflow_instructions) }

    context 'without the filters key' do
      let(:workflow_instructions) { {} }

      it { is_expected.to be_valid }
    end

    context 'without filters' do
      let(:workflow_instructions) { { filters: {} } }

      it { is_expected.to be_valid }
    end

    context 'with unsupported filters' do
      let(:workflow_instructions) { { filters: { something: {}, else: {}, repositories: {} } } }

      it 'is not valid and has an error message' do
        subject.valid?
        expect(subject.errors.full_messages.to_sentence).to eq('Filters something and else are unsupported and ' \
                                                               "Documentation for filters: #{described_class::DOCUMENTATION_LINK}")
      end
    end

    context 'with unsupported filter values' do
      let(:workflow_instructions) { { filters: { event: [], repositories: { only: [], something: [] }, architectures: { else: [] } } } }

      it 'is not valid and has an error message' do
        subject.valid?
        expect(subject.errors.full_messages.to_sentence).to eq('Filter event only supports a string value, ' \
                                                               "Filters repositories and architectures have unsupported values, 'only' and 'ignore' are the only supported values., and " \
                                                               "Documentation for filters: #{described_class::DOCUMENTATION_LINK}")
      end
    end

    context 'with supported filters and filter values' do
      let(:workflow_instructions) { { filters: { event: 'something', repositories: { only: [] }, architectures: { ignore: [] } } } }

      it { is_expected.to be_valid }
    end
  end
end
