require "rails_helper"

# Módulo 15 (ADR 0027; spec 2026-10-05 §3): o banco garante o que o modelo não
# vê — perfil completo ou ausente, um pendente por protocolo por par, só
# pending → taken|expired, período e posição do catálogo, contagem ≥ 1.
RSpec.describe "Guardas das tabelas do catálogo de triagens" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:admin) { staff_with("catalogo-#{SecureRandom.hex(3)}@cidade.gov.br") }
  let!(:protocol) { active_protocol!("saude-do-idoso") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:triage) { completed_triage!(citizen, "saude-do-idoso") }

  def suggestion!(**attrs)
    ApplicationRecord.transaction(requires_new: true) do
      TriageSuggestion.create!({ citizen: citizen, source_triage: triage, protocol_name: "saude-mental" }.merge(attrs))
    end
  end

  it "perfil: tudo ou nada, e profile_source só declared/verified" do
    expect { sql_in_savepoint("UPDATE citizens SET profile_source = 'declared' WHERE id = '#{citizen.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_citizens_profile_complete/)
    expect { sql_in_savepoint("UPDATE citizens SET birth_date = 'x', sex = 'y', profile_source = 'cadsus' WHERE id = '#{citizen.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_citizens_profile_source/)
    expect { sql_in_savepoint("UPDATE citizens SET birth_date = 'x', sex = 'y', profile_source = 'declared' WHERE id = '#{citizen.id}'") }
      .not_to raise_error
  end

  it "uma sugestão pendente por protocolo por par; resolvida não conta" do
    first = suggestion!
    expect { suggestion! }.to raise_error(ActiveRecord::RecordNotUnique)
    first.update!(status: "expired", resolved_at: Time.current)
    expect { suggestion! }.not_to raise_error
  end

  it "transições: só pending → taken | expired; resolvida congela; DELETE passa" do
    taken = suggestion!
    expect { taken.update!(status: "taken", taken_triage_id: triage.id, resolved_at: Time.current) }.not_to raise_error
    {
      "status = 'pending', resolved_at = NULL, taken_triage_id = NULL" => /pending refused|ck_triage_suggestions/,
      "status = 'expired', taken_triage_id = NULL" => /refused|ck_triage_suggestions/,
      "resolved_at = now() - interval '1 day'" => /frozen/,
      "protocol_name = 'outro'" => /only the status columns/
    }.each do |assignment, error|
      expect { sql_in_savepoint("UPDATE triage_suggestions SET #{assignment} WHERE id = '#{taken.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, error), assignment
    end
    expect { sql_in_savepoint("DELETE FROM triage_suggestions WHERE id = '#{taken.id}'") }.not_to raise_error
  end

  # Por SQL: o enum do modelo levanta ArgumentError antes de chegar ao banco.
  def insert_suggestion(status:, resolved_at: "NULL", taken: "NULL")
    sql_in_savepoint("INSERT INTO triage_suggestions (id, citizen_id, source_triage_id, protocol_name, status, " \
                     "taken_triage_id, created_at, resolved_at) VALUES (gen_random_uuid(), '#{citizen.id}', " \
                     "'#{triage.id}', 'x', '#{status}', #{taken}, now(), #{resolved_at})")
  end

  it "CHECKs de sugestão: status conhecido, resolved_at ⇔ resolvida, taken ⇔ taken_triage_id" do
    expect { insert_suggestion(status: "lixo", resolved_at: "now()") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_triage_suggestions_status/)
    expect { insert_suggestion(status: "expired") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_triage_suggestions_resolved/)
    expect { insert_suggestion(status: "expired", resolved_at: "now()", taken: "'#{triage.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_triage_suggestions_taken/)
  end

  it "catálogo: nome único, período em ordem, posição 1..10000" do
    TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: admin)
    expect { TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: admin) }
      .to raise_error(ActiveRecord::RecordInvalid)
    expect { sql_in_savepoint("UPDATE triage_offers SET available_from = '2026-10-10', available_until = '2026-10-09'") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_triage_offers_period/)
    expect { sql_in_savepoint("UPDATE triage_offers SET position = 0") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_triage_offers_position/)
  end

  it "contagem diária soma por (dia, protocolo) e nunca grava zero" do
    day = Time.zone.today
    TriageOfferDailyCount.increment!(%w[a b], day: day)
    TriageOfferDailyCount.increment!(%w[a], day: day)
    TriageOfferDailyCount.increment!([], day: day)
    expect(TriageOfferDailyCount.where(day: day).order(:protocol_name).pluck(:protocol_name, :offered))
      .to eq([ [ "a", 2 ], [ "b", 1 ] ])
    expect { sql_in_savepoint("UPDATE triage_offer_daily_counts SET offered = 0") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_triage_offer_daily_counts_offered/)
  end
end
