require "rails_helper"

# Cobre cada answer_type de Citizens::AnswerValidator.valid? (Review Focus 1
# do plano do canal web: até agora só os booleans tinham teste). O motor não
# recusa resposta fora do esperado (Protocols::Protocol#evaluate); é este
# validador quem impede a web de gravar uma resposta sem ramo.
RSpec.describe Citizens::AnswerValidator do
  def step(answer_type:, options: nil)
    Protocols::Step.new(id: :q, prompt: "?", answer_type: answer_type, options: options)
  end

  describe ".valid?" do
    context "boolean" do
      let(:s) { step(answer_type: :boolean) }

      it { expect(described_class.valid?(s, "true")).to be(true) }
      it { expect(described_class.valid?(s, "false")).to be(true) }
      it { expect(described_class.valid?(s, "sim")).to be(false) }
    end

    context "enum" do
      let(:s) { step(answer_type: :enum, options: %w[leve moderada grave]) }

      it "aceita uma opção existente" do
        expect(described_class.valid?(s, "moderada")).to be(true)
      end

      it "recusa uma opção fora da lista" do
        expect(described_class.valid?(s, "gravissima")).to be(false)
      end
    end

    context "integer" do
      let(:s) { step(answer_type: :integer) }

      it { expect(described_class.valid?(s, "3")).to be(true) }
      it { expect(described_class.valid?(s, "-1")).to be(false) }
      it { expect(described_class.valid?(s, "12345")).to be(false) }
      it { expect(described_class.valid?(s, "3.5")).to be(false) }
      it { expect(described_class.valid?(s, "")).to be(false) }
    end

    context "text" do
      let(:s) { step(answer_type: :text) }

      it "recusa vazio" do
        expect(described_class.valid?(s, "")).to be(false)
      end

      it "recusa só espaço" do
        expect(described_class.valid?(s, "   ")).to be(false)
      end

      it "aceita até 500 caracteres" do
        expect(described_class.valid?(s, "a" * 500)).to be(true)
      end

      it "recusa 501 caracteres" do
        expect(described_class.valid?(s, "a" * 501)).to be(false)
      end
    end
  end
end
