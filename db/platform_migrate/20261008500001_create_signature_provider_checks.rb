# Última conversa da plataforma com cada PSC (ADR 0032; contrato §8): o
# maintenance mostra "credencial presente" e "última checagem". Só a chave do
# catálogo, o instante e se deu certo — nunca segredo, URL, CPF ou resposta.
# `simulated` (ADR 0032, revisão): o PSC simulado também registra a checagem.
class CreateSignatureProviderChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :signature_provider_checks, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :provider, null: false
      t.datetime :last_check_at, null: false
      t.boolean :last_check_ok, null: false
      t.timestamps
      t.index :provider, unique: true
      t.check_constraint "provider::text = ANY (ARRAY['vidaas'::text, 'birdid'::text, 'safeid'::text, 'neoid'::text, 'remoteid'::text, 'simulated'::text])",
                         name: "ck_signature_provider_checks_provider"
    end
  end
end
