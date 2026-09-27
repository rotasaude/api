require "rails_helper"

# F-07.1 (ADR-0014; fechamento do módulo 07): domain_events é a trilha de
# auditoria da cidade — só acréscimo. A única mudança aceita é marcar a
# publicação (published_at de NULL para um valor, uma vez), que o
# IdempotentConsumer faz por update_all. DELETE só passa para evento além da
# retenção de 12 meses: é o TTL da purga (F-07.3) imposto pelo próprio banco,
# não pelo job. O trigger fecha o caminho que o modelo não fecha (update_column,
# delete_all, psql com o papel de runtime) — não o DONO da tabela, ver
# db/city_triggers.sql.
RSpec.describe "domain_events append-only" do
  def attempt
    ApplicationRecord.transaction(requires_new: true) { yield }
  end

  def make_event(occurred_at: Time.current, published_at: nil)
    DomainEvent.create!(name: "triage.completed", payload: { "triage_id" => SecureRandom.uuid },
                        occurred_at: occurred_at, published_at: published_at)
  end

  let!(:event) { make_event }

  describe "UPDATE" do
    it "aceita marcar a publicação uma vez (caminho do IdempotentConsumer)" do
      DomainEvent.where(id: event.id, published_at: nil).update_all(published_at: Time.current)
      expect(event.reload.published_at).to be_present
    end

    it "recusa mudar a publicação depois de marcada" do
      DomainEvent.where(id: event.id).update_all(published_at: Time.current)
      expect { attempt { DomainEvent.where(id: event.id).update_all(published_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /domain_events: already published/)
      expect { attempt { DomainEvent.where(id: event.id).update_all(published_at: 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /domain_events: already published/)
    end

    it "recusa mudar nome, payload, ocorrência ou criação, mesmo por update_all" do
      { name: "triage.urgent", payload: { "x" => 1 }, occurred_at: 1.day.ago, created_at: 1.day.ago }.each do |col, value|
        expect { attempt { DomainEvent.where(id: event.id).update_all(col => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /domain_events: only published_at may change/), col.to_s
      end
      expect { attempt { DomainEvent.where(id: event.id).update_all(name: "x", published_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /domain_events: only published_at may change/)
      expect(event.reload.name).to eq("triage.completed")
    end
  end

  describe "DELETE" do
    it "recusa apagar evento dentro da retenção de 12 meses, mesmo por delete_all" do
      recent = make_event(occurred_at: 11.months.ago)
      [event, recent].each do |ev|
        expect { attempt { DomainEvent.where(id: ev.id).delete_all } }
          .to raise_error(ActiveRecord::StatementInvalid, /domain_events is append-only: DELETE refused inside retention/)
        expect(DomainEvent.exists?(ev.id)).to be(true)
      end
    end

    it "aceita apagar evento além da retenção (a purga de 12 meses)" do
      old = make_event(occurred_at: 13.months.ago)
      DomainEvent.where(id: old.id).delete_all
      expect(DomainEvent.exists?(old.id)).to be(false)
    end
  end

  describe "modelo" do
    it "trata evento gravado como somente leitura" do
      expect { event.update!(name: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  it "nasce com o trigger instalado no banco da cidade" do
    triggers = ApplicationRecord.connection.select_values(<<~SQL)
      SELECT tgname FROM pg_trigger WHERE tgrelid = 'domain_events'::regclass AND NOT tgisinternal
    SQL
    expect(triggers).to include("domain_events_guard")
  end
end
