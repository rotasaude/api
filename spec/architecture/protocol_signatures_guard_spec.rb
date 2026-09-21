require "rails_helper"

# Spec de assinaturas §10: um caminho novo que publique ou ative protocolo sem
# passar pela verificação de assinaturas derrubaria a regra inteira sem nenhum
# teste vermelho. Esta guarda lê o código.
RSpec.describe "Protocol signatures guard" do
  # M4 (rodada de revisão final): a forma round-1 exigia um nome de método de
  # escrita (update!/update_all/...) IMEDIATAMENTE antes de `status:` — e por
  # isso não pegava update!(activated_at: ..., status: "active") (status não é
  # o primeiro kwarg). A forma daqui não amarra a um método: qualquer lugar
  # onde `status` (keyword `status:`, símbolo `:status` posicional depois de
  # update_column/update_attribute/write_attribute, atributo `.status =` ou
  # `[:status] =`) é associado ao valor published/active — string OU símbolo —
  # conta, não importa o que vem antes na linha. Método, não constante:
  # constante dentro de RSpec.describe vaza para Object.
  def status_value
    /"published"|"active"|:published(?!\w)|:active(?!\w)/
  end

  # Fix final do Plano 2 (Minor 1): mais três formas — chave de hash string ou
  # símbolo com `=>` (`update!("status" => "active")`), e SQL em string, com o
  # valor literal em aspas simples (`update_all("status = 'active'")`) ou por
  # placeholder com o valor mais adiante NA MESMA LINHA
  # (`update_all(["status = ?", "active"])`). Leitura continua limpa pelo mesmo
  # critério de sempre: o `(` que envolve o match abre um where(/find_by(.
  def status_write
    /
      \bstatus:\s*(?:#{status_value})                                             |
      \.status\s*=\s*(?:#{status_value})                                          |
      \[:status\]\s*=\s*(?:#{status_value})                                       |
      (?:update_column|update_attribute|write_attribute)\s*\(\s*:status\s*,\s*(?:#{status_value}) |
      (?:"status"|'status'|:status)\s*=>\s*(?:#{status_value})                    |
      \bstatus\s*=\s*'(?:published|active)'                                        |
      \bstatus\s*=\s*\?[^\n]*?(?:#{status_value})
    /x
  end

  # Task 2: a forma round-1 (M4 acima) excluía QUALQUER match com um token de
  # leitura (where(/find_by(/exists?(/==/!=/scope/include?) numa janela de ±3
  # linhas — e por isso deixava passar o padrão comum "ler, conferir, gravar":
  # `version = ProtocolDefinition.find_by(...)` numa linha e
  # `version.update!(status: "published")` duas linhas abaixo formam UMA
  # leitura e UMA escrita, não uma leitura protegendo a escrita — mas a janela
  # via as duas juntas e apagava a escrita da lista de ofensores. A decisão
  # agora é POR INSTRUÇÃO, nunca por proximidade: para o trecho de escrita
  # encontrado, anda-se para trás, caractere a caractere, até o `(` não
  # fechado que o envolve (mesma ideia de casar parênteses de um linter). Só é
  # leitura quando ESSE `(` — o que efetivamente envolve o `status` — abre um
  # where(/find_by(/exists?(. Escrita encadeada a um where
  # (`where(...).update_all(status: ...)`) não ganha essa proteção: o `(` que
  # envolve `status:` ali é do update_all, não do where — o where(/find_by(/
  # exists?( já fechou o próprio parêntese antes. E texto solto sem `(`
  # nenhum ao redor (`record.status = "active"`, `record[:status] = "active"`
  # fora de qualquer chamada) não tem como ser leitura: é escrita por
  # eliminação.
  def read_call?(name)
    name.match?(/\A(where|find_by|find_by!|exists\?)\z/)
  end

  # Fix round 1 (revisão do Task 2): métodos de ESCRITA reconhecidos quando
  # NÃO há `(` nenhum envolvendo o match — chamada sem parênteses, Ruby
  # válido (`protocol.update! status: "active"`). Confirma escrita pelo NOME
  # do método — nunca por eliminação pura. Eliminação pura foi exatamente o
  # que deixou passar o achado do fix round 1: sem fronteira de instrução
  # (ver unclosed_paren_before abaixo), a travessia para trás cruzava
  # `def`/`end`/linha em branco/comentário e achava um `(` de OUTRA
  # instrução, bem mais atrás no arquivo, como se fosse o `where(` desta.
  def write_call?(name)
    name.match?(/\A(update|update!|update_all|update_column|update_columns|
                    assign_attributes|update_attribute|write_attribute)\z/x)
  end

  # Fix round 1: apaga o CONTEÚDO de comentário (do `#` que não está dentro
  # de string até a quebra de linha) inteiro, e SÓ os caracteres `(`/`)` de
  # dentro de literal de string ("..."/'...', respeitando `\"`/`\'`) — não a
  # string inteira. Um `(` solto dentro de `"fallback lookup where ("` ou
  # depois de um `#` de comentário À DIREITA de código de verdade não pode
  # contar como parêntese; a forma de antes só apagava comentário de LINHA
  # INTEIRA (`line.strip.start_with?`), que deixa passar comentário à direita
  # e qualquer string literal.
  #
  # Apagar a string INTEIRA (tentativa anterior a esta) quebra o próprio
  # `status_write`: o valor que ele precisa casar — `"active"`/`"published"`
  # — é UM LITERAL DE STRING, e apagado ele some do texto antes do regex
  # rodar (achado rodando este arquivo: toda a suíte de auto-teste ficava
  # vermelha, inclusive os dez casos originais que não tinham nada a ver com
  # o achado do fix round 1). Só neutralizar `(`/`)` resolve o bug sem
  # destruir o valor que a guarda existe para achar — nenhum dos valores
  # monitorados (`"active"`, `"published"`) tem parêntese dentro.
  def blank_strings_and_comments(source)
    out = source.dup
    i = 0
    len = out.length
    while i < len
      char = out[i]
      if char == "#"
        i += 1
        while i < len && out[i] != "\n"
          out[i] = " "
          i += 1
        end
      elsif char == '"' || char == "'"
        quote = char
        i += 1
        while i < len && out[i] != quote
          if out[i] == "\\" && i + 1 < len
            i += 1
            out[i] = " " if out[i] == "(" || out[i] == ")"
            i += 1
            next
          end
          out[i] = " " if out[i] == "(" || out[i] == ")"
          i += 1
        end
        i += 1
      else
        i += 1
      end
    end
    out
  end

  # Fix round 1: um `\n` só é atravessado quando alguma das duas pontas diz
  # que a instrução continua — a linha anterior termina em vírgula, `(`,
  # `[`, `{`, `|` ou `\` (lista/bloco/expressão partida ao meio), ou a linha
  # seguinte começa com `.`/`&.` (encadeamento de método, como em
  # `Activate`: `.where(...)\n.where.not(...)\n.update_all(...)` — embora
  # nesse caso específico a escrita já resolva na própria linha, sem precisar
  # cruzar nada). Qualquer outra coisa — inclusive `end`, `def`, linha em
  # branco — é fronteira de instrução: para. Roda sobre o texto JÁ sem
  # comentário/string (blank_strings_and_comments corre antes, em
  # protocol_status_write_in?): senão um comentário à direita faria a linha
  # parecer terminar em outra coisa que não o `(` de verdade que vem antes
  # dele.
  def statement_continues_across?(text, newline_idx)
    before_start = (text.rindex("\n", newline_idx - 1) || -1) + 1
    before_line = text[before_start...newline_idx].rstrip
    return true if before_line.end_with?(",", "(", "[", "{", "|", "\\")

    after_end = text.index("\n", newline_idx + 1) || text.length
    after_line = text[(newline_idx + 1)...after_end].lstrip
    after_line.start_with?(".", "&.")
  end

  # Anda por CARACTERE (não por linha nem por janela) — sustenta o caso
  # multi-linha que já vivia aqui antes (o "where(" de
  # conversation_advance.rb abre duas linhas acima do "status:" que fecha) —
  # mas PARA na fronteira da instrução (fix round 1): sem essa borda, a
  # travessia atravessava o arquivo inteiro e podia achar um `(` de outra
  # instrução — ver statement_continues_across? e write_call? acima para o
  # achado que motivou isto.
  def unclosed_paren_before(text, pos)
    depth = 0
    i = pos - 1
    while i >= 0
      char = text[i]
      return nil if char == "\n" && depth.zero? && !statement_continues_across?(text, i)

      case char
      when ")" then depth += 1
      when "("
        return i if depth.zero?
        depth -= 1
      end
      i -= 1
    end
    nil
  end

  # Nome do método logo antes de um `(` — só word chars (e opcionalmente um
  # `!`/`?` final, de update!/exists?): `\z` ancorado bem no paren_idx garante
  # que é O MÉTODO DESSE `(`, não qualquer identificador solto mais atrás.
  def call_before(text, paren_idx)
    text[0...paren_idx].match(/([A-Za-z_][A-Za-z0-9_]*[!?]?)\s*\z/)
  end

  # `receptor.método(` logo antes de um `(` — usado só para distinguir
  # `city.update!(status: "active")` (não é protocolo) de
  # `protocol.update!(status: "active")` (é).
  def receiver_before(text, paren_idx)
    text[0...paren_idx].match(/(@?[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*[A-Za-z_][A-Za-z0-9_]*[!?]?\s*\z/)
  end

  # app/jobs/provision_city_job.rb toca ProtocolDefinition (SeedProtocol.call
  # se ProtocolDefinition.exists?(...) ainda não rodou) e, na mesma classe,
  # também escreve city.update!(status: "active") — a CIDADE, não o
  # protocolo. Task 2 tira a janela de proximidade com "protocol" (que
  # sustentava essa distinção antes) e põe no lugar uma lista EXPLÍCITA e
  # comentada de receptores que não são protocolo, em vez de adivinhar por
  # texto perto. Não exaustiva por design: só os receptores que hoje aparecem
  # num arquivo que também toca ProtocolDefinition.
  def non_protocol_receiver?(receiver)
    %w[city @city City].include?(receiver)
  end

  # Índice do `(` que introduz esta escrita. Para
  # update_column/update_attribute/write_attribute o método (e o `(` dele) já
  # fazem parte do match — não precisam de travessia para trás. Para
  # `status:`/`.status =`/`[:status] =` é o `(` não fechado mais próximo,
  # achado andando para trás a partir do começo do match
  # (unclosed_paren_before).
  def enclosing_paren_index(text, match)
    if match[0].match?(/\A(?:update_column|update_attribute|write_attribute)/)
      return match.begin(0) + match[0].index("(")
    end

    unclosed_paren_before(text, match.begin(0))
  end

  # Com `(` na MESMA instrução: leitura só se o método que o abre é
  # where/find_by/find_by!/exists?; senão, escrita — a menos que o receptor
  # seja explicitamente não-protocolo. Sem `(` (unclosed_paren_before parou
  # na fronteira da instrução, ou nunca houve nenhum): `.status =`/
  # `[:status] =` são atribuição — não têm como ser leitura, escrita sem
  # mais pergunta; `status:` solto (chamada sem parênteses) só confirma
  # escrita pelo NOME do método antes (write_call?) — nunca por eliminação
  # pura (fix round 1: eliminação pura foi o que deixou passar um `(`
  # perdido bem mais atrás no arquivo como se fosse o `where(`/`find_by(`
  # desta instrução).
  def write_at?(text, match)
    paren_idx = enclosing_paren_index(text, match)

    if paren_idx
      method = call_before(text, paren_idx)
      return false if method && read_call?(method[1])

      receiver = receiver_before(text, paren_idx)
      return false if receiver && non_protocol_receiver?(receiver[1])

      return true
    end

    return true if match[0].match?(/\A(?:\.status\s*=|\[:status\]\s*=)/)

    method = call_before(text, match.begin(0))
    return true if method && write_call?(method[1])
    return false if method && read_call?(method[1])

    true
  end

  # A literal ProtocolDefinition, não a palavra "protocol": app/commands/
  # conversation_advance.rb menciona "protocol" (DEFAULT_PROTOCOL_NAME, a
  # chave de tradução no_protocol) — exigir a literal, em vez de "protocol\b",
  # mantém no escopo todo arquivo que de fato manipula o registro de
  # protocolo, e só esse.
  #
  # Fix final do Plano 2 (Minor 1): lib/ também — lib/dashboard_demo.rb grava
  # status de protocolo, e a guarda não olhava para lá.
  def app_files_touching_protocols
    Dir[Rails.root.join("{app,lib}/**/*.rb")].select { |path| File.read(path).include?("ProtocolDefinition") }
  end

  # Separado de protocol_status_write? (que lê arquivo) para o auto-teste
  # abaixo poder provar o MÉTODO de detecção direto em trecho sintético, sem
  # precisar escrever e apagar arquivo em disco a cada caso.
  def protocol_status_write_in?(source)
    text = blank_strings_and_comments(source)

    matches = []
    text.scan(status_write) { matches << Regexp.last_match }

    matches.any? { |match| write_at?(text, match) }
  end

  def protocol_status_write?(path)
    protocol_status_write_in?(File.read(path))
  end

  it "writes a protocol status of published or active only in the three signed-act commands" do
    allowed = %w[publish.rb activate.rb revert_activation.rb].map { |f| Rails.root.join("app/commands/protocols", f).to_s }
    # ÚNICA exceção fora dos commands, e explícita: lib/dashboard_demo.rb é dado
    # de demonstração de desenvolvimento (bin/rails db:seed:demo, nunca em
    # produção), que cria versões já active/published direto na tabela —
    # passar pelos commands exigiria autor, dois revisores e step-up fictícios
    # só para popular um painel. A versão active ganha a mesma linha-base do
    # db/seeds.rb (DashboardDemo#ensure_baseline_activation). Hoje o arquivo
    # passa o status por variável (`p.status = status`), forma que a guarda
    # não enxerga — ela só casa valor LITERAL. A exceção fica escrita aqui
    # assim mesmo: o arquivo está fora da regra por decisão registrada, não
    # por um ponto cego da regex.
    allowed << Rails.root.join("lib/dashboard_demo.rb").to_s

    offenders = app_files_touching_protocols.reject { |path| allowed.include?(path) }
                                            .select { |path| protocol_status_write?(path) }

    expect(offenders).to be_empty
  end

  it "scans lib/ as well as app/" do
    expect(app_files_touching_protocols).to include(Rails.root.join("lib/dashboard_demo.rb").to_s)
  end

  # Fix round 1 — auto-teste do MÉTODO de detecção, em trecho sintético, sem
  # precisar de arquivo em disco nem da literal ProtocolDefinition (esse
  # filtro é de app_files_touching_protocols, uma camada acima, alheia ao
  # que está sendo provado aqui). Mesmo espírito de
  # spec/architecture/maintenance_schema_spec.rb: prova o CAMINHO DE CÓDIGO,
  # não só a regex — e funciona como regressão permanente para os dez casos
  # que motivaram o Task 2 e para o achado do fix round 1, sem depender de
  # escrever e apagar arquivo temporário a cada rodada.
  context "detection self-test (per statement, not by proximity)" do
    def flags(source) = protocol_status_write_in?(source)

    # Achado do fix round 1 (reproduzido pela revisão): um `(` perdido num
    # COMENTÁRIO À DIREITA de código de verdade, muito antes no arquivo, não
    # pode contar como o parêntese desta instrução — a travessia sem
    # fronteira cruzava `end`/linha em branco/`def` e achava esse `(` como
    # se fosse um `where(` de verdade, deixando passar a escrita sem
    # parênteses como se fosse leitura.
    it "flags a parens-less write even with a stray '(' inside an earlier trailing comment" do
      source = <<~RUBY
        class Something
          def helper
            x = 1 # fallback lookup where (
          end

          def other
            protocol.update! status: "active"
          end
        end
      RUBY

      expect(flags(source)).to be true
    end

    # A mesma forma, com o `(` perdido dentro de um LITERAL DE STRING
    # (código de verdade, não comentário) — blank_strings_and_comments apaga
    # o miolo da string antes de qualquer varredura, e a fronteira de
    # instrução já para antes de a travessia chegar lá de qualquer jeito.
    it "flags a parens-less write even with a stray '(' inside an earlier string literal" do
      source = <<~RUBY
        class Something
          def helper
            x = "fallback lookup find_by ("
          end

          def other
            protocol.update! status: "active"
          end
        end
      RUBY

      expect(flags(source)).to be true
    end

    # Escrita sem parênteses nenhum, valor símbolo — confirmada por
    # write_call?("update!"), não por eliminação.
    it "flags a parens-less write with a symbol value" do
      expect(flags('protocol.update! status: :active')).to be true
    end

    # Os dez casos do Task 2 original (8 do brief, o 7º com 3 formas),
    # mantidos aqui como regressão permanente em vez de arquivo temporário
    # escrito e apagado a cada rodada.
    it "flags read-then-write across separate statements (find_by, then update! two lines later)" do
      source = <<~RUBY
        version = ProtocolDefinition.find_by(name: n)

        version.update!(status: "published")
      RUBY

      expect(flags(source)).to be true
    end

    it "flags a write on the line right after an unrelated status comparison" do
      source = <<~RUBY
        if protocol.status == "in_review"
          protocol.update!(status: "published")
        end
      RUBY

      expect(flags(source)).to be true
    end

    it "flags a write on the line right after an unrelated include? guard" do
      source = <<~RUBY
        return unless ALLOWED.include?(x)

        record.update!(status: "active")
      RUBY

      expect(flags(source)).to be true
    end

    it "flags a write chained off a variable assigned from a where on an earlier statement" do
      source = <<~RUBY
        scope = ProtocolDefinition.where(name: n)

        scope.first.update!(status: "active")
      RUBY

      expect(flags(source)).to be true
    end

    it "flags status outside the first kwarg position" do
      expect(flags('record.update!(activated_at: Time.current, status: "active")')).to be true
    end

    it "flags a symbol value" do
      expect(flags("record.update!(status: :published)")).to be true
    end

    it "flags update_attribute" do
      expect(flags('record.update_attribute(:status, "active")')).to be true
    end

    it "flags write_attribute" do
      expect(flags('record.write_attribute(:status, "active")')).to be true
    end

    it "flags a bracket attribute assignment" do
      expect(flags('record[:status] = "active"')).to be true
    end

    it "flags a write chained onto a where" do
      expect(flags('ProtocolDefinition.where(name: n).update_all(status: "active")')).to be true
    end

    # E os casos que precisam continuar limpos — a mesma distinção que o
    # Task 2 original provou contra o código real, aqui fixada como trecho
    # sintético, para nunca mais depender só do scan do app/ para pegar uma
    # regressão nestes três.
    it "clears a status kwarg read inside a where(, even split across lines" do
      source = <<~RUBY
        record = ProtocolDefinition.where(
          name: DEFAULT_PROTOCOL_NAME,
          status: "active"
        ).first
      RUBY

      expect(flags(source)).to be false
    end

    it "clears a status write whose receiver is explicitly not the protocol (city)" do
      expect(flags('city.update!(status: "active")')).to be false
    end

    it "clears a status kwarg read inside a find_by!( (fix round 1: read_call? addition)" do
      expect(flags('protocol = ProtocolDefinition.find_by!(name: n, status: "active")')).to be false
    end

    # Fix final do Plano 2 (Minor 1): as formas que a guarda ainda não via —
    # hash de chave string (ou símbolo com =>) e escrita por SQL em string.
    it "flags a string-key hash write" do
      expect(flags('protocol.update!("status" => "active")')).to be true
    end

    it "flags a hash-rocket symbol-key write" do
      expect(flags('protocol.update!(:status => "published")')).to be true
    end

    it "flags a SQL-string update_all" do
      expect(flags(%q{ProtocolDefinition.where(name: n).update_all("status = 'active'")})).to be true
    end

    it "flags a SQL-string update_all with a bound value" do
      expect(flags('ProtocolDefinition.where(name: n).update_all(["status = ?", "active"])')).to be true
    end

    it "flags a SQL-string update_all that sets status after another column" do
      expect(flags('scope.update_all(["activated_at = ?, status = ?", Time.current, "published"])')).to be true
    end

    it "clears the same new forms when they are a read inside where(" do
      expect(flags('ProtocolDefinition.where("status" => "active")')).to be false
      expect(flags(%q{ProtocolDefinition.where("status = 'active'")})).to be false
      expect(flags('ProtocolDefinition.where("status = ?", "active")')).to be false
    end
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
    # M8 (rodada de revisão final): grant_role.rb e invite_member.rb passaram
    # de denylist (actor_kind == "maintainer") para allowlist (actor_kind ==
    # "user") — mesma forma que sign.rb já usava. As três checagens hoje usam
    # o mesmo padrão.
    {
      "app/commands/protocols/sign.rb" => /actor_kind\s*==\s*"user"/,
      "app/commands/grant_role.rb" => /actor_kind\s*==\s*"user"/,
      "app/commands/invite_member.rb" => /actor_kind\s*==\s*"user"/
    }.each do |file, pattern|
      expect(File.read(Rails.root.join(file))).to match(pattern), "#{file} não checa o tipo de ator"
    end
  end
end
