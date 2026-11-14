require "rails_helper"
require Rails.root.join("db/platform_migrate/20261113900001_create_field_maps.rb").to_s

# Módulo 24c (ADR 0053; contrato §3.1, Q30, Q31): o mapa offline por município
# na plataforma. `field_maps` tem uma linha por cidade; o ESTADO descreve a
# última geração e o ARQUIVO PUBLICADO (versão, tamanho, SHA-256, chave) é
# outra coisa: continua servido enquanto a nova geração roda ou falha.
# `field_map_bases` guarda a base de onde os recortes saem. Nenhum dado de pessoa.
RSpec.describe "Esquema do mapa de campo (ADR 0053)", type: :model do
  SHA = ("ab" * 32).freeze

  def refused(pattern = nil, &block)
    expect { PlatformRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { PlatformRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  let!(:city) { home_visit_city! }
  let(:city_id) { city.id }
  let(:published) do
    { version: Date.new(2026, 11, 1), size_bytes: 41_234_567, sha256: SHA,
      storage_key: "field-maps/cities/#{city_id}/2026-11-01-abababababab.pmtiles", built_at: Time.current }
  end

  def map(**over) = FieldMap.new({ city_id: city_id, state: "building", requested_at: Time.current }.merge(over))

  describe "field_maps" do
    it "uma linha por cidade" do
      map.save!
      expect { map.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique, /field_maps/)
    end

    it "estado da lista; failed exige error_code, e só ele" do
      refused(/ck_field_maps_state/) { map(state: "queued").save!(validate: false) }
      refused(/ck_field_maps_error/) { map(state: "failed").save!(validate: false) }
      refused(/ck_field_maps_error/) { map(state: "ready", error_code: "extract_failed").save!(validate: false) }
      refused(/ck_field_maps_error/) { map(state: "failed", error_code: "outro").save!(validate: false) }
      FieldMaps::Catalog::ERROR_CODES.each do |code|
        accepted { map(state: "failed", error_code: code).save!; FieldMap.where(city_id: city_id).delete_all }
      end
    end

    it "o arquivo publicado é tudo ou nada, com SHA-256 de 64 hex e tamanho positivo" do
      published.each_key do |missing|
        refused(/ck_field_maps_published/) { map(state: "ready", **published.except(missing)).save!(validate: false) }
      end
      refused(/ck_field_maps_sha256/) { map(state: "ready", **published, sha256: "AB" * 32).save!(validate: false) }
      refused(/ck_field_maps_sha256/) { map(state: "ready", **published, sha256: "ab" * 31).save!(validate: false) }
      refused(/ck_field_maps_published/) { map(state: "ready", **published, size_bytes: 0).save!(validate: false) }
      accepted { map(state: "ready", **published).save! }
    end

    it "o publicado continua na linha enquanto a nova geração roda ou falha (Q30)" do
      row = map(state: "ready", **published)
      row.save!
      row.update!(state: "building", requested_at: Time.current)
      expect(row.reload).to be_published
      row.update!(state: "failed", error_code: "extract_failed")
      expect(FieldMap.published_for(city_id)).to eq(row)
      expect(row.manifest).to eq(version: "2026-11-01", size_bytes: 41_234_567, sha256: SHA)
    end

    it "manifest e published_for: nil sem arquivo publicado" do
      row = map
      row.save!
      expect(row).not_to be_published
      expect(row.manifest).to be_nil
      expect(FieldMap.published_for(city_id)).to be_nil
      expect(FieldMap.published_for(SecureRandom.uuid)).to be_nil
    end

    it "inspect só com a cidade e o estado" do
      row = map(state: "ready", **published)
      expect(row.inspect).to eq("#<FieldMap city_id=#{city_id} state=ready>")
    end
  end

  describe "field_map_bases" do
    def base(**over) = FieldMapBase.new({ version: Date.new(2026, 11, 13), state: "copying", source_url: "https://example.test/20261113.pmtiles" }.merge(over))

    let(:ready) { { state: "ready", storage_key: "field-maps/base/2026-11-13.pmtiles", size_bytes: 900_000_000, sha256: SHA, ready_at: Time.current } }

    it "uma base por versão; estado e erro da lista; ready tem o arquivo inteiro" do
      base.save!
      expect { base.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique, /field_map_bases/)
      refused(/ck_field_map_bases_state/) { base(version: Date.new(2026, 11, 14), state: "building").save!(validate: false) }
      refused(/ck_field_map_bases_error/) { base(version: Date.new(2026, 11, 14), state: "failed").save!(validate: false) }
      refused(/ck_field_map_bases_ready/) { base(version: Date.new(2026, 11, 14), **ready.except(:sha256)).save!(validate: false) }
      refused(/ck_field_map_bases_ready/) { base(version: Date.new(2026, 11, 14), sha256: SHA).save!(validate: false) }
      accepted { base(version: Date.new(2026, 11, 14), **ready).save! }
      accepted { base(version: Date.new(2026, 11, 15), state: "failed", error_code: "base_missing").save! }
    end

    it "current é a ready de maior versão; age_days conta os dias da versão" do
      expect(FieldMapBase.current).to be_nil
      base(version: Date.new(2026, 10, 1), **ready, storage_key: "field-maps/base/2026-10-01.pmtiles").save!
      newest = base(version: Date.new(2026, 11, 13), **ready)
      newest.save!
      base(version: Date.new(2026, 11, 20)).save! # copying: ainda não vale
      expect(FieldMapBase.current).to eq(newest)
      expect(newest.age_days(Date.new(2026, 12, 13))).to eq(30)
      expect(newest.inspect).to eq("#<FieldMapBase version=2026-11-13 state=ready>")
    end
  end

  it "a migração é irreversível e espelha o catálogo" do
    expect { CreateFieldMaps.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect([ CreateFieldMaps::STATES, CreateFieldMaps::ERROR_CODES, CreateFieldMaps::BASE_STATES ])
      .to eq([ FieldMaps::Catalog::STATES, FieldMaps::Catalog::ERROR_CODES, FieldMaps::Catalog::BASE_STATES ])
  end
end
