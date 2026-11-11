require "rails_helper"

# Módulo 33 (ADR 0051): setores da secretaria. Nunca apagados (trigger), nome
# único sem distinguir caixa; ExamFile ganha a finalidade do anexo da ouvidoria.
RSpec.describe Department do
  let(:user) { User.create!(email_address: "ouvidoria@cidade.gov.br", password: "senha-segura-123") }

  def build_department(name) = described_class.create!(name: name, updated_by_user: user)

  it "o banco recusa nome repetido com outra caixa" do
    build_department("Regulação")
    expect { build_department("rEGULAÇÃO") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "valida o tamanho do nome e filtra os ativos" do
    expect(described_class.new(name: "x", updated_by_user: user)).not_to be_valid
    expect(described_class.new(name: "x" * 81, updated_by_user: user)).not_to be_valid
    active = build_department("Farmácia")
    inactive = build_department("Almoxarifado")
    inactive.update!(active: false)
    expect(described_class.active).to contain_exactly(active)
  end

  it "recusa apagar" do
    build_department("Transporte")
    expect { described_class.first.destroy }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
  end

  it "recusa TRUNCATE" do
    expect { ApplicationRecord.connection.execute("TRUNCATE departments") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  describe "ExamFile.purpose ombudsman_attachment" do
    def attrs(purpose)
      bytes = "%PDF-1.4 x"
      { content_type: "application/pdf", byte_size: bytes.bytesize, sha256: "0" * 64,
        data: Base64.strict_encode64(bytes), uploaded_by_user: user, purpose: purpose }
    end

    it "aceita a finalidade nova" do
      expect { ExamFile.create!(**attrs("ombudsman_attachment")) }.not_to raise_error
      expect(ExamFile::PURPOSES).to include("ombudsman_attachment")
    end

    it "recusa finalidade desconhecida" do
      expect { ExamFile.create!(**attrs("x")) }.to raise_error(ActiveRecord::StatementInvalid, /ck_exam_files_purpose/)
    end
  end
end
