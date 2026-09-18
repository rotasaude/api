require "rails_helper"

# Spec de assinaturas §10: um caminho novo que publique ou ative protocolo sem
# passar pela verificação de assinaturas derrubaria a regra inteira sem nenhum
# teste vermelho. Esta guarda lê o código.
RSpec.describe "Protocol signatures guard" do
  # Escrita de status de protocolo para published/active, em qualquer forma usual:
  # update!/update/update_all/update_columns/assign_attributes com status: "..."
  # (keyword); update_column com :status posicional (:status, "..."); ou atribuição
  # direta (.status = "..."). Fix round 1 (ruling P3): update_column posicional e
  # assign_attributes (seguido de save) também contam — passavam batido antes.
  # Método, não constante: constante dentro de RSpec.describe vaza para Object.
  def status_write
    /(update!?|update_all|update_columns?|assign_attributes)\s*\(?\s*status:\s*"(published|active)"|\.status\s*=\s*"(published|active)"|update_column\s*\(\s*:status\s*,\s*"(published|active)"/
  end

  # A literal ProtocolDefinition, não a palavra "protocol": app/commands/
  # conversation_advance.rb menciona "protocol" (DEFAULT_PROTOCOL_NAME, a
  # chave de tradução no_protocol) e tem uma linha com status: "active" — mas
  # é a CONVERSA que muda de estado ali (@conversation.update!(state: ...));
  # a linha com status: "active" é uma leitura (ProtocolDefinition.where(name:,
  # status: "active")), não uma escrita, então nem chega a casar com
  # status_write. Exigir a literal ProtocolDefinition, em vez de "protocol\b",
  # mantém no escopo todo arquivo que de fato manipula o registro de
  # protocolo, e só esse.
  def app_files_touching_protocols
    Dir[Rails.root.join("app/**/*.rb")].select { |path| File.read(path).include?("ProtocolDefinition") }
  end

  # Arquivo inteiro não basta: app/jobs/provision_city_job.rb toca
  # ProtocolDefinition (SeedProtocol.call se ProtocolDefinition.exists?(...)
  # ainda não rodou) e, longe dali, na mesma classe, também escreve
  # city.update!(status: "active") — a CIDADE, não o protocolo. Um filtro
  # por "escreve status published/active em algum lugar do arquivo" marcaria
  # esse arquivo como ofensor por um motivo errado. Por isso a checagem é por
  # janela: a escrita só conta quando "protocol" aparece perto dela (poucas
  # linhas antes/depois), o bastante para pegar `protocol.update!(status:
  # "published")` (Publish/Activate) sem confundir com a escrita de status de
  # outro modelo que mora no mesmo arquivo.
  # Janela de ±3 linhas mantida como estava (fix round 1 não mexeu nisso): as
  # formas novas (update_column posicional, assign_attributes) aparecem na
  # mesma linha do objeto que as chama, igual às formas já cobertas — nenhuma
  # delas pede uma janela diferente.
  def protocol_status_write?(path)
    lines = File.readlines(path)
    lines.each_with_index.any? do |line, i|
      next false unless line.match?(status_write)

      lines[[i - 3, 0].max..(i + 3)].join.match?(/protocol/i)
    end
  end

  it "writes a protocol status of published or active only in the three signed-act commands" do
    allowed = %w[publish.rb activate.rb revert_activation.rb].map { |f| Rails.root.join("app/commands/protocols", f).to_s }

    offenders = app_files_touching_protocols.reject { |path| allowed.include?(path) }
                                            .select { |path| protocol_status_write?(path) }

    expect(offenders).to be_empty
  end

  it "makes publish and activate ask Protocols::Signatures before the act" do
    # Fix round 1 (ruling P3): comentário mencionando Signatures.missing( não
    # basta — o header de publish.rb já cita isso em prosa. Só linhas de
    # código contam; linha cujo texto (sem espaço à esquerda) começa com "#"
    # é descartada antes de procurar a chamada real.
    %w[publish.rb activate.rb].each do |file|
      code = File.readlines(Rails.root.join("app/commands/protocols", file))
                 .reject { |line| line.strip.start_with?("#") }
                 .join
      expect(code).to include("Signatures.missing("), "#{file} publica/ativa sem perguntar as assinaturas"
    end
  end

  it "refuses the maintainer by kind of actor wherever approval is created" do
    {
      "app/commands/protocols/sign.rb" => /actor_kind\s*==\s*"user"/,
      "app/commands/grant_role.rb" => /actor_kind\s*==\s*"maintainer"/,
      "app/commands/invite_member.rb" => /actor_kind\s*==\s*"maintainer"/
    }.each do |file, pattern|
      expect(File.read(Rails.root.join(file))).to match(pattern), "#{file} não checa o tipo de ator"
    end
  end
end
