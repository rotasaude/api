# spec/models/campaign_tables_guard_spec.rb
require "rails_helper"

# Módulo 12 (ADR 0024; spec §3): a campanha enviada é imutável e do
# destinatário só mudam a leitura (uma vez) e o SMS. O banco recusa por SQL
# direto, sem passar pelo modelo.
RSpec.describe "Guardas das tabelas de campanha" do
  let(:author) { staff_with("autor@cidade.gov.br") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "status, título, texto, agendamento, falha e cancelamento são garantidos por CHECK" do
    campaign = draft_campaign!(by: author)
    {
      "status = 'lixo'" => /ck_campaigns_status/,
      "status = 'scheduled'" => /ck_campaigns_send_at/,
      "status = 'failed'" => /ck_campaigns_failure/,
      "failure_reason = 'below_minimum'" => /ck_campaigns_failure/,
      "cancelled_at = now()" => /ck_campaigns_cancelled/,
      "title = ' Gripe'" => /ck_campaigns_title/,
      "title = 'ab'" => /ck_campaigns_title/,
      "body = 'curto'" => /ck_campaigns_body/
    }.each do |assignment, error|
      expect { sql_in_savepoint("UPDATE campaigns SET #{assignment} WHERE id = '#{campaign.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, error), assignment
    end
  end

  it "rascunho muda livremente" do
    campaign = draft_campaign!(by: author)
    expect { campaign.update!(title: "Outro título", audience: city_audience) }.not_to raise_error
  end

  it "enviada ou cancelada: nenhuma coluna muda e não se apaga" do
    sent = sent_campaign!(by: author)
    [ "title = 'Mudou depois'", "recipients_count = 99", "status = 'draft'" ].each do |assignment|
      expect { sql_in_savepoint("UPDATE campaigns SET #{assignment} WHERE id = '#{sent.id}'") }
        .to raise_error(ActiveRecord::StatementInvalid, /frozen after send/), assignment
    end
    expect { sql_in_savepoint("DELETE FROM campaigns WHERE id = '#{sent.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /only a draft may be deleted/)

    cancelled = draft_campaign!(by: author)
    cancelled.update_columns(status: "cancelled", cancelled_by_user_id: author.id, cancelled_at: Time.current)
    expect do
      sql_in_savepoint("UPDATE campaigns SET status = 'draft', cancelled_at = NULL, cancelled_by_user_id = NULL " \
                       "WHERE id = '#{cancelled.id}'")
    end.to raise_error(ActiveRecord::StatementInvalid, /frozen after send/)
  end

  it "em sending, só vai a sent ou failed, e só com as colunas do congelamento" do
    campaign = draft_campaign!(by: author)
    campaign.update_columns(status: "sending", dispatched_by_user_id: author.id)
    expect { sql_in_savepoint("UPDATE campaigns SET status = 'draft' WHERE id = '#{campaign.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /sending only moves to sent or failed/)
    expect { sql_in_savepoint("UPDATE campaigns SET status = 'sent', title = 'Outro título' WHERE id = '#{campaign.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /only the freeze columns/)
    expect { sql_in_savepoint("UPDATE campaigns SET status = 'failed', failure_reason = 'below_minimum' WHERE id = '#{campaign.id}'") }
      .not_to raise_error
  end

  it "destinatário: só a leitura (uma vez) e o SMS mudam; apagar é permitido" do
    campaign = sent_campaign!(by: author)
    row = recipient!(campaign, citizen)
    expect { row.update!(sms_status: "sent", sms_sent_at: Time.current) }.not_to raise_error
    expect { row.update!(notice_read_at: Time.current) }.not_to raise_error
    expect { sql_in_savepoint("UPDATE campaign_recipients SET notice_read_at = NULL WHERE id = '#{row.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /notice_read_at is set once/)
    expect { sql_in_savepoint("UPDATE campaign_recipients SET notice_read_at = now() WHERE id = '#{row.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /notice_read_at is set once/)
    other = draft_campaign!(by: author)
    expect { sql_in_savepoint("UPDATE campaign_recipients SET campaign_id = '#{other.id}' WHERE id = '#{row.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /only the reading and the SMS columns/)
    expect { sql_in_savepoint("UPDATE campaign_recipients SET sms_status = 'lixo' WHERE id = '#{row.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_campaign_recipients_sms_status/)
    expect { row.destroy! }.not_to raise_error
  end

  it "um destinatário por cidadão e campanha" do
    campaign = sent_campaign!(by: author)
    recipient!(campaign, citizen)
    expect { recipient!(campaign, citizen) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "preferência de contato: padrões desligados, uma linha por cidadão" do
    preference = CitizenContactPreference.create!(citizen: citizen)
    expect(preference).to have_attributes(sms_opt_in: false, notices_muted: false, citizen_id: citizen.id)
    expect { CitizenContactPreference.create!(citizen: citizen) }.to raise_error(ActiveRecord::RecordNotUnique)

    other = Citizen.create!(cpf: "11144477735", phone: "+5541998765433")
    expect(CitizenContactPreference.for(other.id))
      .to have_attributes(sms_opt_in: false, notices_muted: false, new_record?: true)
    expect(CitizenContactPreference.for(citizen.id)).to eq(preference)
  end

  it "city_profile nasce com o SMS de campanha desligado" do
    expect(CityProfile.create!(name: "Cidade Teste").campaigns_sms_enabled).to be(false)
  end

  it "o banco aceita o papel campaign_manager" do
    user = staff_with("campanhas@cidade.gov.br")
    expect do
      sql_in_savepoint("INSERT INTO memberships (id, user_id, role, granted_at, created_at, updated_at) " \
                       "VALUES (gen_random_uuid(), '#{user.id}', 'campaign_manager', now(), now(), now())")
    end.not_to raise_error
  end
end
