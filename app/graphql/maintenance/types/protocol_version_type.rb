module Maintenance
  module Types
    # Uma versão de protocolo e o estado de assinatura dela (spec de
    # assinaturas §5, ADR-0016), para o mantenedor saber ANTES de gastar um
    # TOTP se publicar/ativar vai passar. Só contagens e booleanos: quem
    # assinou (e-mail, id) não sai pela API de manutenção. Tudo vem das
    # funções que os commands usam — este tipo não reimplementa regra.
    #
    # Lido sem lock: pode ficar obsoleto assim que outra escrita comita. A
    # decisão de verdade é a do command, que trava a linha e reconfere.
    #
    # Os valores chegam PRONTOS num Hash montado por CityType#protocol_versions:
    # a conexão da cidade (CityReader) fecha ao sair do `inside`, então nada
    # aqui pode consultar o banco — mesmo desenho de CityCountsType.
    class ProtocolVersionType < BaseObject
      description "Versão de protocolo com estado de assinatura (contagens, sem identidade de revisor)."

      field :name, String, null: false
      field :version, Integer, null: false
      field :status, String, null: false
      field :publication_signatures, Integer, null: false
      field :publication_missing, Integer, null: false
      field :activation_signatures, Integer, null: false
      field :activation_missing, Integer, null: false
      field :eligible_reviewers, Integer, null: false
      field :revertible, Boolean, null: false
      field :revert_target_version, Integer, null: true,
            description: "Versão que voltaria a valer numa reversão de emergência; nula quando não há."
    end
  end
end
