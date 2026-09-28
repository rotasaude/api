require "rails_helper"

# Módulo 11 (ADR 0023): o bairro copiado na triagem nunca muda; o banco recusa
# por SQL direto, sem passar pelo modelo. Nome, origem, par de cobertura e CEP
# também são garantidos pelo banco.
RSpec.describe "Guardas das tabelas de território" do
  # Savepoint por chamada: cada `sql` pode falhar de propósito — é o que
  # estamos testando —, e sem isolamento o erro do Postgres deixaria a
  # transação da fixture abortada para o resto do exemplo (nenhum comando
  # novo é aceito até ROLLBACK). Mesmo padrão de
  # spec/models/professional_tables_guard_spec.rb.
  def sql(statement) = ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(statement) }

  def insert_neighborhood(name_sql, source_sql)
    sql("INSERT INTO neighborhoods (id, name, source, active, created_at, updated_at) " \
        "VALUES (gen_random_uuid(), #{name_sql}, #{source_sql}, true, now(), now())")
  end

  let(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let(:batel) { Neighborhood.create!(name: "Batel", source: "manual") }

  it "triagem: o bairro gravado no INSERT não muda por UPDATE, nem para nulo" do
    triage = territory_triage!(centro)
    expect { sql("UPDATE triages SET neighborhood_id = '#{batel.id}' WHERE id = '#{triage.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /neighborhood_id never changes/)
    expect { sql("UPDATE triages SET neighborhood_id = NULL WHERE id = '#{triage.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /neighborhood_id never changes/)
  end

  it "revogação: ir para NULL passa quando a linha fica (ou está) em aborted_by_revocation; outro bairro, não" do
    triage = territory_triage!(centro, status: "in_progress")
    expect { sql("UPDATE triages SET neighborhood_id = NULL, status = 'aborted_by_revocation' WHERE id = '#{triage.id}'") }
      .not_to raise_error
    expect(triage.reload.neighborhood_id).to be_nil

    revoked = territory_triage!(centro, status: "in_progress")
    sql("UPDATE triages SET status = 'aborted_by_revocation' WHERE id = '#{revoked.id}'")
    expect { sql("UPDATE triages SET neighborhood_id = '#{batel.id}' WHERE id = '#{revoked.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /neighborhood_id never changes/)
    expect { sql("UPDATE triages SET neighborhood_id = NULL WHERE id = '#{revoked.id}'") }.not_to raise_error
  end

  it "triagem sem bairro não ganha bairro depois; as outras colunas continuam mudando" do
    triage = territory_triage!(nil, status: "in_progress")
    expect { sql("UPDATE triages SET neighborhood_id = '#{centro.id}' WHERE id = '#{triage.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /neighborhood_id never changes/)
    expect { triage.update!(current_step: "febre") }.not_to raise_error
  end

  it "bairro: nome único sem diferenciar maiúsculas, pelo índice" do
    centro
    expect { insert_neighborhood("'CENTRO'", "'manual'") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "bairro: seed_key única quando presente; várias nulas convivem" do
    Neighborhood.create!(name: "Centro", source: "seed", seed_key: "centro")
    expect { Neighborhood.create!(name: "Centro Novo", source: "seed", seed_key: "centro") }
      .to raise_error(ActiveRecord::RecordNotUnique)
    Neighborhood.create!(name: "Batel", source: "manual")
    expect { Neighborhood.create!(name: "Ahu", source: "manual") }.not_to raise_error
  end

  it "bairro: nome vazio, com espaço nas pontas ou origem desconhecida é recusado pelo CHECK" do
    expect { insert_neighborhood("'  '", "'manual'") }.to raise_error(ActiveRecord::StatementInvalid, /ck_neighborhoods_name/)
    expect { insert_neighborhood("' Batel'", "'manual'") }.to raise_error(ActiveRecord::StatementInvalid, /ck_neighborhoods_name/)
    expect { insert_neighborhood("'Ahu'", "'import'") }.to raise_error(ActiveRecord::StatementInvalid, /ck_neighborhoods_source/)
  end

  it "cobertura: o par (bairro, unidade) é único" do
    unit = create_unit
    NeighborhoodCoverage.create!(neighborhood: centro, health_unit: unit)
    expect { NeighborhoodCoverage.create!(neighborhood: centro, health_unit: unit) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "unidade: CEP só com 8 dígitos" do
    unit = create_unit
    expect { sql("UPDATE health_units SET address_zip = '8002031' WHERE id = '#{unit.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_health_units_address_zip/)
    expect { sql("UPDATE health_units SET address_zip = '80020310' WHERE id = '#{unit.id}'") }.not_to raise_error
  end
end
