require "rails_helper"
require Rails.root.join("db/city_migrate/20261126900001_add_regulation_rnds.rb").to_s

# Módulo 26c (Task 5; Valor 4; Q6, Q16, Q17): as tabelas do envio da regulação
# à RNDS. O banco segura o formato (catálogos fechados nos CHECKs); os triggers
# seguram o que o código não pode quebrar: o estado por pedido e as remessas
# nunca somem; a remessa só perde o payload (qualquer uma, aceita ou não: Q17)
# e grava a resposta uma vez.
RSpec.describe "Esquema do envio da regulação à RNDS (módulo 26c)", type: :model do
  let!(:city) { regulation_city! }
  # let!: nunca nasce dentro do savepoint de um `refused` (seria desfeita e ficaria memoizada).
  let!(:request) { regulation_request!(status: "draft") }

  def sync!(regulation_request = request, **over)
    RegulationRndsSync.create!({ regulation_request: regulation_request, status: "queued", enqueued_at: Time.current }.merge(over))
  end

  def delivery!(sync, **over)
    RegulationRndsDelivery.create!({ regulation_rnds_sync: sync, kind: "create", mira_status: "pending", payload: '{"resourceType":"Bundle"}',
                                     digest: "a" * 64, sent_at: Time.current }.merge(over))
  end

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "a migração espelha Regulation::RndsCatalog e a lista de credenciais; irreversível" do
    catalog = Regulation::RndsCatalog
    expect([ AddRegulationRnds::MIRA_STATUSES, AddRegulationRnds::SYNC_STATUSES, AddRegulationRnds::DELIVERY_KINDS,
             AddRegulationRnds::DEFAULT_PRIORITY_BY_COLOR ])
      .to eq([ catalog::MIRA_STATUSES, catalog::SYNC_STATUSES, catalog::DELIVERY_KINDS, catalog::DEFAULT_PRIORITY_BY_COLOR ])
    expect(AddRegulationRnds::CREDENTIAL_KINDS).to eq(IntegrationCredential::KINDS)
    expect { AddRegulationRnds.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  describe "regulation_rnds_settings" do
    it "RegulationRndsSetting.current nasce com vermelho → urgent; linha única" do
      setting = RegulationRndsSetting.current
      expect(setting).to have_attributes(id: 1, specialty_sigtap: {}, send_external: false, version: 1, updated_by_user_id: nil)
      expect(setting.priority_by_color).to eq(Regulation::RndsCatalog::DEFAULT_PRIORITY_BY_COLOR)
      expect(setting.priority_by_color["red"]).to eq("urgent")
      expect(RegulationRndsSetting.current).to eq(setting)
      refused(/ck_regulation_rnds_settings_singleton/) { RegulationRndsSetting.create!(id: 2, updated_at: Time.current) }
    end

    it "DELETE e TRUNCATE recusados (Fix round 2)" do
      setting = RegulationRndsSetting.current
      refused(/regulation_rnds_settings : DELETE refused/) { setting.delete }
      refused(/append-only: TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE regulation_rnds_settings") }
      expect(RegulationRndsSetting.exists?(1)).to be(true)
    end
  end

  describe "regulation_rnds_syncs" do
    it "um sync por pedido (único)" do
      sync!
      expect { sync! }.to raise_error(ActiveRecord::RecordNotUnique, /regulation_request/)
      expect(sync!(regulation_request!(status: "draft"))).to be_persisted
    end

    it "bundle_identifier nasce uuid; `RECUSA-<uuid>` passa, `a b` cai; único" do
      expect(sync!.bundle_identifier).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      identifier = "RECUSA-#{SecureRandom.uuid}"
      marked = sync!(regulation_request!(status: "draft"), bundle_identifier: identifier)
      expect(marked).to be_persisted
      refused(/ck_regulation_rnds_syncs_bundle_identifier/) { marked.update_columns(bundle_identifier: "a b") }
      expect { ApplicationRecord.transaction(requires_new: true) { marked.update_columns(bundle_identifier: "x" * 65) } }
        .to raise_error(ActiveRecord::ValueTooLong)
      expect { sync!(regulation_request!(status: "draft"), bundle_identifier: identifier) }
        .to raise_error(ActiveRecord::RecordNotUnique, /bundle_identifier/)
    end

    it "status fora do catálogo → CHECK; enqueued_at obrigatório" do
      row = sync!
      Regulation::RndsCatalog::SYNC_STATUSES.each { |status| row.update_columns(status: status) }
      refused(/ck_regulation_rnds_syncs_status/) { row.update_columns(status: "accepted") }
      refused(/enqueued_at/) { row.update_columns(enqueued_at: nil) }
    end

    it "`sent_status` `booked` passa, `scheduled` cai; o mesmo no desejado; nulos passam" do
      row = sync!
      expect(row).to have_attributes(sent_status: nil, desired_status: nil, pending_steps: [], blocked_reasons: [], last_error_codes: [],
                                     attempts: 0, initial_load: false, claimed_at: nil)
      row.update_columns(sent_status: "booked", desired_status: "returned-to-requester")
      refused(/ck_regulation_rnds_syncs_sent_status/) { row.update_columns(sent_status: "scheduled") }
      refused(/ck_regulation_rnds_syncs_desired_status/) { row.update_columns(desired_status: "scheduled") }
    end

    it "retry_window_started_at: timestamptz nulo; reopen_retry_window! o zera (o Reenviar da Task 14)" do
      column = RegulationRndsSync.columns_hash["retry_window_started_at"]
      expect([ column.sql_type, column.null ]).to eq([ "timestamp with time zone", true ])
      row = sync!(retry_window_started_at: 20.days.ago)
      row.reopen_retry_window!
      expect(row.reload.retry_window_started_at).to be_nil
    end

    it "DELETE → trigger; inspect só id e situação" do
      row = sync!(bundle_identifier: "MARCA-#{SecureRandom.hex(8)}")
      refused(/regulation_rnds_syncs : DELETE refused/) { row.delete }
      expect(row.inspect).to eq("#<RegulationRndsSync id=#{row.id} status=queued>")
    end
  end

  describe "regulation_rnds_deliveries" do
    let(:sync) { sync! }

    it "DELETE → trigger" do
      row = delivery!(sync)
      refused(/regulation_rnds_deliveries : DELETE refused/) { row.delete }
    end

    it "kind fora do catálogo → CHECK; remessa `delete` sem payload passa" do
      expect { delivery!(sync, kind: "update") }.to raise_error(ActiveRecord::StatementInvalid, /ck_regulation_rnds_deliveries_kind/)
      expect(delivery!(sync, kind: "delete", mira_status: nil, payload: nil, digest: nil)).to be_persisted
    end

    it "anular payload passa (aceita ou não, Q17); trocar `kind` ou o payload → trigger" do
      open = delivery!(sync)
      accepted = delivery!(sync)
      accepted.update_columns(accepted_at: Time.current, rnds_id: "rnds-1", http_status: 201)
      refused(/only the payload/) { open.update_columns(kind: "replace") }
      refused(/payload only becomes NULL/) { open.update_columns(payload: '{"outro":1}') }
      open.update_columns(payload: nil)
      accepted.update_columns(payload: nil)
      expect([ open.reload.payload, accepted.reload.payload ]).to eq([ nil, nil ])
      refused(/payload only becomes NULL/) { open.update_columns(payload: '{"volta":1}') }
    end

    it "a resposta grava uma vez; sent_at, digest e situação nunca mudam" do
      row = delivery!(sync)
      row.update_columns(rnds_id: "rnds-2", accepted_at: Time.current) # a adoção (sem resposta HTTP)
      refused(/recorded once/) { row.update_columns(rnds_id: "rnds-3") }
      refused(/recorded once/) { row.update_columns(accepted_at: nil) }
      refused(/only the payload/) { row.update_columns(sent_at: 1.day.ago) }
      refused(/only the payload/) { row.update_columns(digest: "b" * 64) }
      refused(/only the payload/) { row.update_columns(mira_status: "booked") }
    end

    # Fix round 2 (Q25): a resposta só se grava enquanto não houve resposta HTTP.
    it "respondida (http_status gravado) → nenhuma coluna de resposta muda mais; a resposta inteira num UPDATE passa" do
      refused_row = delivery!(sync)
      refused_row.update_columns(http_status: 422, error_codes: %w[EHR-ERR825])
      refused(/only while unanswered|recorded once/) { refused_row.update_columns(http_status: 201) }
      refused(/only while unanswered|recorded once/) { refused_row.update_columns(error_codes: %w[EDS-MSG009]) }
      refused(/only while unanswered/) { refused_row.update_columns(rnds_id: "rnds-9", accepted_at: Time.current) }

      unavailable = delivery!(sync)
      unavailable.update_columns(http_status: 503)
      refused(/only while unanswered/) { unavailable.update_columns(error_codes: %w[EHR-ERR999]) }
      refused(/only while unanswered/) { unavailable.update_columns(accepted_at: Time.current) }

      accepted = delivery!(sync)
      accepted.update_columns(http_status: 201, rnds_id: "rnds-10", accepted_at: Time.current)
      expect(accepted.reload).to have_attributes(http_status: 201, rnds_id: "rnds-10")
    end

    # Final wave, item 3: a adotada não ganha resposta depois; a fechada pela reconciliação não é adotada.
    it "adotada (accepted_at sem http_status) não grava http_status nem error_codes; fechada (unanswered_closed_at) não é adotada" do
      adopted = delivery!(sync)
      adopted.update_columns(accepted_at: Time.current, rnds_id: "rnds-12")
      refused(/adopted/) { adopted.update_columns(http_status: 201) }
      refused(/adopted/) { adopted.update_columns(error_codes: %w[EHR-ERR999]) }
      expect(adopted.reload).to have_attributes(http_status: nil, error_codes: [])

      closed = delivery!(sync)
      closed.update_columns(unanswered_closed_at: Time.current)
      refused(/closed/) { closed.update_columns(accepted_at: Time.current, rnds_id: "rnds-13") }
      refused(/closed/) { closed.update_columns(accepted_at: Time.current) }
      expect(closed.reload).to have_attributes(accepted_at: nil, rnds_id: nil)
      closed.update_columns(payload: nil) # Q17: a purga segue valendo
    end

    it "unanswered_closed_at: uma vez, só na remessa sem resposta nem aceite; depois dela a payload ainda some" do
      columns = RegulationRndsDelivery.columns_hash
      expect([ columns["unanswered_closed_at"].sql_type, columns["unanswered_closed_at"].null ]).to eq([ "timestamp with time zone", true ])
      open = delivery!(sync)
      open.update_columns(unanswered_closed_at: Time.current)
      refused(/unanswered_closed_at/) { open.update_columns(unanswered_closed_at: 1.minute.from_now) }
      refused(/unanswered_closed_at/) { open.update_columns(unanswered_closed_at: nil) }
      open.update_columns(payload: nil)
      expect(open.reload.payload).to be_nil

      answered = delivery!(sync)
      answered.update_columns(http_status: 503)
      refused(/unanswered_closed_at/) { answered.update_columns(unanswered_closed_at: Time.current) }
      adopted = delivery!(sync)
      adopted.update_columns(accepted_at: Time.current, rnds_id: "rnds-11")
      refused(/unanswered_closed_at/) { adopted.update_columns(unanswered_closed_at: Time.current) }
      [ answered, adopted ].each { |row| row.update_columns(payload: nil) } # Q17: a purga vale em qualquer remessa
      expect([ answered.reload.payload, adopted.reload.payload ]).to eq([ nil, nil ])
    end

    it "payload cifrado com a chave da cidade; re-cifra sob a marca passa; inspect sem payload" do
      row = delivery!(sync, payload: '{"cpf":"52998224725"}')
      raw = ApplicationRecord.connection.select_value(
        RegulationRndsDelivery.sanitize_sql([ "SELECT payload FROM regulation_rnds_deliveries WHERE id = ?", row.id ])
      )
      expect(raw).not_to include("52998224725")
      expect(row.reload.payload).to eq('{"cpf":"52998224725"}')
      other = create(:city)
      expect {
        ActiveRecord::Encryption.with_encryption_context(**CityEncryption.context_properties(other)) do
          ActiveRecord::Encryption.encryptor.decrypt(raw)
        end
      }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
      expect(CityEncryption::CITY_KEYED_TARGETS).to include([ RegulationRndsDelivery, :payload ])

      CityEncryption.allowing_reencryption { row.encrypt }
      expect(row.reload.payload).to eq('{"cpf":"52998224725"}')
      expect([ row.inspect, row.to_s, row.as_json.to_s ].join).not_to include("52998224725")
      expect(row.inspect).to eq("#<RegulationRndsDelivery id=#{row.id} kind=create http_status=nil>")
    end
  end

  describe "CBO do executante" do
    let(:provider) { external_provider! }

    it "`performer_cbo` `12345` → CHECK; seis dígitos ou nulo passam (oferta e prestador)" do
      offer = offer!(provider: provider)
      offer.update_columns(performer_cbo: "225125")
      refused(/ck_care_offers_performer_cbo/) { offer.update_columns(performer_cbo: "12345") }
      offer.update_columns(performer_cbo: nil)
      provider.update_columns(default_performer_cbo: "225120")
      refused(/ck_care_providers_default_performer_cbo/) { provider.update_columns(default_performer_cbo: "22512A") }
    end
  end

  describe "regulation_request_events (Q24): o horário e o prestador da falta" do
    it "scheduled_at, ends_at e care_provider_id nulos; FK do prestador; a linha segue só acréscimo" do
      columns = RegulationRequestEvent.columns_hash
      expect(columns.slice("scheduled_at", "ends_at", "care_provider_id").transform_values { |c| [ c.sql_type, c.null ] })
        .to eq("scheduled_at" => [ "timestamp with time zone", true ], "ends_at" => [ "timestamp with time zone", true ],
               "care_provider_id" => [ "uuid", true ])
      provider = external_provider!
      row = RegulationRequestEvent.create!(regulation_request: request, status: "missed", scheduled_at: Time.current,
                                           ends_at: Time.current + 15.minutes, care_provider_id: provider.id)
      expect(row.reload.care_provider).to eq(provider)
      refused(/fk_rails/) do
        RegulationRequestEvent.create!(regulation_request: request, status: "missed", care_provider_id: SecureRandom.uuid)
      end
      refused { row.update_columns(scheduled_at: Time.current + 1.day) }
    end
  end

  it "credencial `rnds_regulation` grava (production)" do
    credential = rnds_regulation_credential!
    expect(credential.reload).to have_attributes(kind: "rnds_regulation", environment: "production")
    refused(/ck_integration_credentials_environment_kind/) { credential.update_columns(environment: "homologation") }
  end
end
