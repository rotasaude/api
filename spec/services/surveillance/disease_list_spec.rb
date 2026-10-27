# spec/services/surveillance/disease_list_spec.rb
require "rails_helper"

RSpec.describe Surveillance::DiseaseList do
  let(:entry) { { "code" => "dengue", "name" => "Dengue (casos)", "deadline" => "weekly", "cid10" => %w[A90], "ciap2" => [],
                  "repeat_after_days" => 30, "sinan_form" => nil, "notes" => nil, "sources" => { "cid10" => "ficha" } } }

  def publish(**args)
    described_class::Publish.call(**{ ordinance: "P", effective_from: Date.current, expected_version: 0, diseases: [ entry ] }.merge(args))
  end

  it "carga idempotente da prova técnica; vigência escolhe a versão" do
    expect(described_class::Load.call).to eq(created: 1)
    expect(described_class::Load.call).to eq(created: 0)
    v1 = NotifiableDiseaseVersion.find_by!(version: 1)
    expect(v1.diseases.count).to eq(71)
    expect(v1.diseases.find_by!(code: "dengue").cid10).to eq(%w[A90])
    expect(v1.sources).to include("ordinance" => a_string_including("11.211"), "sources_dir" => "vendor/surveillance/2026-10-27")
    result = described_class::Publish.call(ordinance: "Portaria X", effective_from: Date.current + 30, diseases: [ entry ], expected_version: 1,
                                           notes: "remove o resto", sources: { "url" => "https://example.test/p" })
    expect(result).to be_ok
    v2 = result.payload[:version]
    expect(v2).to have_attributes(version: 2, notes: "remove o resto", sources: { "url" => "https://example.test/p" })
    expect(v2.diseases.count).to eq(1)
    expect(described_class.current(today: Date.current + 29)).to eq(v1)
    expect(described_class.current(today: Date.current + 30)).to eq(v2)
    expect(described_class.current(today: Date.new(2026, 5, 13))).to be_nil
    event = PlatformEvent.where(name: "notifiable_disease_list.published").last
    expect(event.payload).to eq("notifiable_disease_version_id" => v2.id, "version" => 2, "diseases_count" => 1)
  end

  it "recusa com path: código repetido, categoria cobrindo subcategoria de outra doença, prazo desconhecido" do
    other = entry.merge("code" => "febre_x", "cid10" => %w[A900])
    expect(publish(diseases: [ entry, other ]).details).to eq(path: "diseases.1.cid10.0")
    bad = entry.merge("deadline" => "monthly")
    expect(publish(diseases: [ bad ]).details).to eq(path: "diseases.0.deadline")
    expect(publish(diseases: [ entry.merge("code" => "local_x") ]).details).to eq(path: "diseases.0.code")
    expect(publish(diseases: [ entry, entry.merge("cid10" => %w[B01]) ]).details).to eq(path: "diseases.1.code")
    expect(publish(diseases: [ entry, entry.merge("code" => "febre_x", "cid10" => %w[B01], "ciap2" => %w[A01]),
                               entry.merge("code" => "febre_y", "cid10" => %w[B02], "ciap2" => %w[A01]) ]).details).to eq(path: "diseases.2.ciap2.0")
    expect(publish(diseases: []).details).to eq(path: "diseases")
    expect(NotifiableDiseaseVersion.count).to eq(0)
  end

  it "validate aceita a regra de código como parâmetro (código local)" do
    local = entry.merge("code" => "local_febre_x")
    expect(described_class.validate([ local ])).to be_failure
    expect(described_class.validate([ local ], code_rule: Surveillance::Catalog::LOCAL_CODE)).to be_ok
    expect(described_class.validate([ entry ], code_rule: Surveillance::Catalog::LOCAL_CODE).details).to eq(path: "diseases.0.code")
  end

  it "recusa a publicação sobre versão desatualizada (stale_version)" do
    described_class::Load.call
    result = publish(expected_version: 0, effective_from: Date.current + 1)
    expect(result).to have_attributes(reason: :stale_version)
    expect(publish(expected_version: 1, effective_from: Date.current + 1)).to be_ok
    expect(publish(expected_version: 1, effective_from: Date.current + 2)).to have_attributes(reason: :stale_version)
    expect(publish(expected_version: 2, effective_from: Date.current + 2)).to be_ok
  end

  it "effective_from: nunca no passado nem antes da vigência da última versão" do
    expect(publish(effective_from: Date.current - 1).details).to eq(path: "effective_from")
    expect(publish(effective_from: Date.current + 10)).to be_ok
    expect(publish(expected_version: 1, effective_from: Date.current + 9).details).to eq(path: "effective_from")
    expect(publish(expected_version: 1, effective_from: Date.current + 10)).to be_ok
  end

  it "ordinance e notes têm limite" do
    expect(publish(ordinance: " ").details).to eq(path: "ordinance")
    expect(publish(ordinance: "x" * 201).details).to eq(path: "ordinance")
    expect(publish(notes: "x" * 501).details).to eq(path: "notes")
    expect(publish(ordinance: "x" * 200, notes: "x" * 500)).to be_ok
  end

  # Savepoint: a recusa do banco aborta a transação do exemplo.
  def refused(&) = PlatformRecord.transaction(requires_new: true, &)

  it "versão gravada é imutável no banco" do
    described_class::Load.call
    expect { refused { NotifiableDisease.where(id: NotifiableDisease.first.id).update_all(name: "x") } }
      .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    expect { refused { NotifiableDiseaseVersion.update_all(ordinance: "x") } }.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    expect { refused { NotifiableDisease.delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    expect { NotifiableDisease.first.update_columns(name: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "o banco recusa código de plataforma fora da regra" do
    described_class::Load.call
    v = NotifiableDiseaseVersion.first
    attrs = { list_version_id: v.id, name: "X", deadline: "weekly", cid10: [], ciap2: [], repeat_after_days: 30, sources: {} }
    expect { refused { NotifiableDisease.create!(attrs.merge(code: "local_x")) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_notifiable_diseases_code/)
    expect { refused { NotifiableDisease.create!(attrs.merge(code: "xx", deadline: "monthly")) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_notifiable_diseases_deadline/)
  end

  it "o dump da plataforma carrega as duas tabelas" do
    dump = File.read(Rails.root.join("db/platform_schema.rb"))
    expect(dump).to include('create_table "notifiable_disease_versions"', 'create_table "notifiable_diseases"')
    expect(File.read(Rails.root.join("db/platform_triggers.sql"))).to include("notifiable_disease_versions_immutable", "notifiable_diseases_immutable")
  end
end
