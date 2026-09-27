require "rails_helper"

# F-03.14 e critério de fechamento do módulo 03 (ADR 0009): uma versão de
# protocolo nunca é apagada — aposentar é mudar o status — e, depois de
# publicada, o conteúdo dela não muda mais (imutabilidade por versão: triagem e
# relatório apontam para ESTA linha). Rascunho e versão em revisão continuam
# editáveis. O trigger fecha o caminho que o modelo não fecha (update_all,
# delete_all, psql com o papel de runtime) — não o DONO da tabela, ver
# db/city_triggers.sql.
RSpec.describe "protocol_definitions guard" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  # Savepoint na conexão da cidade: cada recusa aborta só o seu savepoint
  # (mesma razão de spec/models/protocol_append_only_spec.rb). let! cria a linha
  # FORA do savepoint — com let preguiçoso ela nasceria dentro e sumiria no rollback.
  def attempt
    ProtocolDefinition.transaction(requires_new: true) { yield }
  end

  def definition(status)
    ProtocolDefinition.create!(name: "dengue-#{status}", version: 1, status: status,
                               definition: protocol_definition_hash)
  end

  let!(:draft)     { definition("draft") }
  let!(:in_review) { definition("in_review") }
  let!(:published) { definition("published") }
  let!(:active)    { definition("active") }
  let!(:retired)   { definition("retired") }

  def changed_content = protocol_definition_hash.merge("recommendations" => { "alta" => { "title" => "outro" } })

  it "refuses DELETE in every status, even through delete_all" do
    [draft, in_review, published, active, retired].each do |row|
      expect { attempt { ProtocolDefinition.where(id: row.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /protocol_definitions: DELETE refused/)
    end
  end

  it "refuses TRUNCATE" do
    expect { attempt { ProtocolDefinition.connection.execute("TRUNCATE protocol_definitions CASCADE") } }
      .to raise_error(ActiveRecord::StatementInvalid, /protocol_definitions is append-only/)
  end

  it "freezes definition, name and version once published" do
    [published, active, retired].each do |row|
      { definition: changed_content, name: "outro", version: 99 }.each do |column, value|
        expect { attempt { ProtocolDefinition.where(id: row.id).update_all(column => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /frozen once published/), "#{row.status}/#{column}"
      end
    end
  end

  it "keeps drafts and versions under review editable" do
    [draft, in_review].each do |row|
      expect { ProtocolDefinition.where(id: row.id).update_all(definition: changed_content) }.not_to raise_error
    end
  end

  it "lets the lifecycle move published ↔ active and on to retired" do
    expect { active.update!(status: "published") }.not_to raise_error
    expect { published.update!(status: "active", activated_at: Time.current) }.not_to raise_error
    expect { active.reload.update!(status: "published") }.not_to raise_error
    expect { active.update!(status: "retired", retired_at: Time.current) }.not_to raise_error
  end

  it "never sends a published version back to draft or review" do
    %w[draft in_review].each do |status|
      expect { attempt { ProtocolDefinition.where(id: published.id).update_all(status: status) } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot go back/)
    end
  end

  it "never brings a retired version back" do
    %w[published active].each do |status|
      expect { attempt { ProtocolDefinition.where(id: retired.id).update_all(status: status) } }
        .to raise_error(ActiveRecord::StatementInvalid, /retired is final/)
    end
  end
end
