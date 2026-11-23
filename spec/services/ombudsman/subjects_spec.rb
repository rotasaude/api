require "rails_helper"

# Módulo 35b, Task 9 (ADR 0054; contrato §4; Q14): os assuntos reservados do
# centro de zoonoses. Ombudsman::Subjects.ensure_zoonoses! garante o pai
# "Zoonoses" (code `zoonoses`) e os oito filhos (`zoonoses.<subtipo>`, com os
# rótulos do §4, lidos de config/zoonoses/domains.yml), idempotente e sob
# pg_advisory_xact_lock; adota o pai (e o filho de mesmo nome) que a cidade
# criou à mão sem code. O assunto com code pode ser renomeado, mas não
# desativado com o zoonoses ligado (409 reserved_subject).
RSpec.describe Ombudsman::Subjects, type: :model do
  let(:labels) { YAML.load_file(Rails.root.join("config/zoonoses/domains.yml")).fetch("subtypes").to_h { |row| row.values_at("code", "label") } }

  def reserved = OmbudsmanSubject.where.not(code: nil)

  describe ".ensure_zoonoses!" do
    before { ombudsman_city! }

    it "duas chamadas → um pai e oito filhos, com os códigos e os rótulos do §4; a semente do 33 continua" do
      first = described_class.ensure_zoonoses!
      second = described_class.ensure_zoonoses!

      expect(reserved.count).to eq(9)
      parent = OmbudsmanSubject.find_by!(code: "zoonoses")
      expect(parent).to have_attributes(name: "Zoonoses", parent_id: nil, active: true)
      expect(first[:parent].id).to eq(parent.id)
      expect(second[:parent].id).to eq(parent.id)
      expect(first[:children].keys).to eq(Zoonoses::Catalog::SUBTYPES)
      expect(second[:children].transform_values(&:id)).to eq(first[:children].transform_values(&:id))
      Zoonoses::Catalog::SUBTYPES.each do |subtype|
        expect(first[:children].fetch(subtype)).to have_attributes(code: "zoonoses.#{subtype}", name: labels.fetch(subtype),
                                                                   parent_id: parent.id, active: true)
      end
      expect(OmbudsmanSubject.where(parent_id: nil).pluck(:name)).to include(*OmbudsmanSubject::DEFAULT_TREE.map(&:first))
    end

    it "toma a trava consultiva da transação quando falta algum assunto" do
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.ensure_zoonoses! }
      expect(statements.grep(/pg_advisory_xact_lock/).size).to eq(1)

      statements.clear
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.ensure_zoonoses! }
      expect(statements.grep(/pg_advisory_xact_lock/)).to be_empty
    end

    it "pai 'zoonoses' criado à mão é adotado (ganha code), e o filho de mesmo nome também, sem duplicar" do
      OmbudsmanSubject.ensure_defaults!
      manual = OmbudsmanSubject.create!(name: "zoonoses", position: 99)
      scorpion = OmbudsmanSubject.create!(name: "escorpião", parent: manual, position: 1)
      own = OmbudsmanSubject.create!(name: "Pombos", parent: manual, position: 2)

      result = described_class.ensure_zoonoses!
      expect(result[:parent].id).to eq(manual.id)
      expect(manual.reload).to have_attributes(code: "zoonoses", name: "zoonoses")
      expect(scorpion.reload).to have_attributes(code: "zoonoses.scorpion", name: "escorpião")
      expect(result[:children].fetch("scorpion").id).to eq(scorpion.id)
      expect(own.reload.code).to be_nil
      expect(OmbudsmanSubject.where(parent_id: nil).where("lower(name) = 'zoonoses'").count).to eq(1)
      expect(OmbudsmanSubject.where(parent_id: manual.id).count).to eq(9)
      expect(reserved.count).to eq(9)
    end

    it "assunto reservado desativado com o gate desligado volta ativo (o encaminhamento automático classifica nele)" do
      described_class.ensure_zoonoses!
      scorpion = OmbudsmanSubject.find_by!(code: "zoonoses.scorpion")
      parent = OmbudsmanSubject.find_by!(code: "zoonoses")
      scorpion.update!(active: false)
      parent.update!(active: false)

      described_class.ensure_zoonoses!
      expect([ scorpion.reload.active, parent.reload.active ]).to eq([ true, true ])
    end
  end

  describe "Ombudsman::SaveSubject com assunto reservado" do
    before { ombudsman_city! }

    let(:subjects) { described_class.ensure_zoonoses! }

    it "desativar com o gate → reserved_subject; renomear passa; gate desligado → desativa" do
      child = subjects[:children].fetch("bat")
      refused = Ombudsman::SaveSubject.call(subject: child, attrs: { "active" => false }, zoonoses: true)
      expect(refused.reason).to eq(:reserved_subject)
      expect(child.reload.active).to be(true)
      expect(Ombudsman::SaveSubject.call(subject: subjects[:parent], attrs: { "active" => false }, zoonoses: true).reason)
        .to eq(:reserved_subject)

      renamed = Ombudsman::SaveSubject.call(subject: child, attrs: { "name" => "Morcegos" }, zoonoses: true)
      expect(renamed).to be_ok
      expect(child.reload).to have_attributes(name: "Morcegos", code: "zoonoses.bat", active: true)
      expect(Ombudsman::SaveSubject.call(subject: child, attrs: { "active" => true }, zoonoses: true)).to be_ok

      off = Ombudsman::SaveSubject.call(subject: child, attrs: { "active" => false }, zoonoses: false)
      expect(off).to be_ok
      expect(child.reload.active).to be(false)
    end

    it "assunto sem code desativa com o gate ligado" do
      leaf = subject_leaf!
      expect(Ombudsman::SaveSubject.call(subject: leaf, attrs: { "active" => false }, zoonoses: true)).to be_ok
      expect(leaf.reload.active).to be(false)
    end
  end

  describe "GET/PATCH /ombudsman/subjects", type: :request do
    let(:ouvidor) { ombudsman! }

    it "o JSON do assunto traz code; com o gate, a listagem garante os reservados; PATCH desativar → 409 reserved_subject" do
      zoonoses_city!
      ombudsman_city!
      sign_in_as(ouvidor)
      get "/ombudsman/subjects"
      expect(response).to have_http_status(:ok)
      items = json_body["items"]
      zoonoses = items.find { |item| item["code"] == "zoonoses" }
      expect(zoonoses).to include("name" => "Zoonoses", "active" => true)
      expect(zoonoses["children"].map { |child| child["code"] }).to eq(Zoonoses::Catalog::SUBTYPES.map { |s| "zoonoses.#{s}" })
      expect(zoonoses["children"].first.keys).to contain_exactly("id", "name", "active", "code")
      seeded = items.find { |item| item["name"] == "Atendimento" }
      expect(seeded["code"]).to be_nil
      expect(seeded["children"].first["code"]).to be_nil

      json_patch "/ombudsman/subjects/#{zoonoses['children'].first['id']}", active: false
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "reserved_subject")
      json_patch "/ombudsman/subjects/#{zoonoses['children'].first['id']}", name: "Escorpiões"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("name" => "Escorpiões", "code" => "zoonoses.scorpion")
    end

    it "gate desligado: a listagem não cria os reservados" do
      ombudsman_city!
      sign_in_as(ouvidor)
      get "/ombudsman/subjects"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |item| item["code"] }.compact).to be_empty
      expect(reserved).to be_empty
    end
  end
end
