require "rails_helper"

RSpec.describe Ombudsman::Catalog do
  it "fixa os vocabulários do plano" do
    expect(described_class::KINDS).to eq(%w[complaint report praise suggestion request])
    expect(described_class::MODES).to eq(%w[identified preserved anonymous])
    expect(described_class::STATES).to eq(%w[received in_analysis forwarded awaiting_complement answered archived])
    expect(described_class::OPEN_STATES).to eq(%w[received in_analysis forwarded awaiting_complement])
    expect(described_class::ARCHIVE_REASONS).to eq(%w[duplicate no_complement lack_of_clarity lack_of_civility improper loss_of_object forwarded_elsewhere])
  end

  it "os eventos do cidadão são um subconjunto dos eventos da linha do tempo" do
    expect(described_class::EVENT_KINDS.size).to eq(18)
    expect(described_class::CITIZEN_EVENT_KINDS - described_class::EVENT_KINDS).to be_empty
    expect(described_class::CITIZEN_EVENT_KINDS).not_to include("classified", "forwarded", "identity_consent_recorded")
  end

  it "publica exatamente os 7 eventos de domínio do contrato" do
    expect(described_class::DOMAIN_EVENTS).to eq(%w[
      ombudsman.manifestation_received ombudsman.forwarded ombudsman.forwarding_replied
      ombudsman.concluded ombudsman.reopened ombudsman.identity_viewed ombudsman.anonymous_cap_reached
    ])
  end

  it "o filtro de log cobre os campos da ouvidoria" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    %w[extract reply manifestant_name manifestant_contact contact ouvidorsus_number external_body_name
       decision_text recurring_problems actions_taken body justification full_name cpf].each do |key|
      expect(filter.filter(key => "texto secreto")[key]).to eq("[FILTERED]"), "#{key} vazaria no log"
    end
  end

  # Q4 (preflight F-15; overrides T1.4): o texto do arquivamento chega pronto ao
  # cidadão, nas palavras dele — um rótulo por motivo.
  it "fixa o rótulo do motivo de arquivamento que o cidadão lê" do
    expect(described_class::ARCHIVE_REASON_CITIZEN_LABELS).to eq(
      "duplicate" => "Já existe outra manifestação com o mesmo pedido.",
      "no_complement" => "O complemento pedido não chegou no prazo.",
      "lack_of_clarity" => "Faltaram informações para entender o pedido.",
      "lack_of_civility" => "A manifestação usou linguagem ofensiva.",
      "improper" => "O pedido não é assunto da Ouvidoria da Saúde.",
      "loss_of_object" => "O motivo do pedido deixou de existir.",
      "forwarded_elsewhere" => "O pedido é de outro órgão e foi encaminhado a ele."
    )
    expect(described_class::ARCHIVE_REASON_CITIZEN_LABELS.keys).to eq(described_class::ARCHIVE_REASONS)
    expect(described_class::ARCHIVE_REASON_CITIZEN_LABELS).to be_frozen
  end
end
