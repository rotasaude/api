# spec/models/terminology_tables_guard_spec.rb
require "rails_helper"

# ADR 0028 (spec 2026-10-05 §4): release ativa nunca muda; release com falha
# nunca fica ativa; códigos só entram numa release em importação e não mudam
# depois de ativa. Garantido pelo banco (db/platform_triggers.sql).
RSpec.describe "Terminologias: guarda do banco" do
  def sql(statement) = PlatformRecord.transaction(requires_new: true) { PlatformRecord.connection.execute(statement) }

  def release!(status: "importing", version: "202610", kind: "sigtap")
    TerminologyRelease.create!(kind: kind, version: version, source_sha256: "a" * 64, imported_by: "rspec",
                               imported_at: Time.current, status: "importing").tap do |r|
      r.update!(status: status, activated_at: (Time.current if status == "active")) unless status == "importing"
    end
  end

  it "transições permitidas: importing → active|failed, active → superseded; o resto é recusado" do
    active = release!(status: "active")
    expect { sql("UPDATE terminology_releases SET status = 'importing' WHERE id = '#{active.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /transition/)
    failed = release!(status: "failed", version: "202609")
    expect { sql("UPDATE terminology_releases SET status = 'active' WHERE id = '#{failed.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /transition/)
    expect { active.update!(status: "superseded") }.not_to raise_error
  end

  it "release ativa ou substituída: nenhum outro campo muda e não se apaga" do
    active = release!(status: "active")
    expect { sql("UPDATE terminology_releases SET version = '202611' WHERE id = '#{active.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    expect { sql("DELETE FROM terminology_releases WHERE id = '#{active.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end

  it "códigos: entram só em release importing; não mudam nem saem de release ativa" do
    importing = release!(kind: "ciap2", version: "2")
    Ciap2Code.create!(release: importing, code: "K86", description: "Hipertensão sem complicações")
    importing.update!(status: "active", activated_at: Time.current)
    expect { sql("INSERT INTO ciap2_codes (release_id, code, description) VALUES ('#{importing.id}', 'T90', 'x')") }
      .to raise_error(ActiveRecord::StatementInvalid, /being imported/)
    expect { sql("UPDATE ciap2_codes SET description = 'y'") }.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    expect { sql("DELETE FROM ciap2_codes") }.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end

  it "no máximo uma ativa por kind e versão; versão da SIGTAP é AAAAMM" do
    release!(status: "active")
    expect { release!(status: "active") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { release!(version: "2026-10") }.to raise_error(ActiveRecord::StatementInvalid)
  end
  it "códigos: não se move linha para fora de release ativa ou substituída (release_id)" do
    active = release!(kind: "ciap2", version: "2")
    Ciap2Code.create!(release: active, code: "K86", description: "x")
    target = release!(kind: "ciap2", version: "3")
    active.update!(status: "active", activated_at: Time.current)
    expect { sql("UPDATE ciap2_codes SET release_id = '#{target.id}'") }.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    active.update!(status: "superseded")
    expect { sql("UPDATE ciap2_codes SET release_id = '#{target.id}'") }.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end
end
