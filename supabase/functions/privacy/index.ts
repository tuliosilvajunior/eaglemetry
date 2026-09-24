const htmlContent = `<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Política de Privacidade – Capy</title>
  <style>
    :root {
      --bg: #0f172a;
      --card-bg: #1e293b;
      --text: #f1f5f9;
      --text-muted: #94a3b8;
      --accent: #10b981;
      --border: #334155;
    }
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f8fafc;
        --card-bg: #ffffff;
        --text: #0f172a;
        --text-muted: #64748b;
        --accent: #059669;
        --border: #e2e8f0;
      }
    }
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background-color: var(--bg);
      color: var(--text);
      line-height: 1.6;
      padding: 2rem 1rem;
    }
    .container {
      max-width: 760px;
      margin: 0 auto;
      background: var(--card-bg);
      padding: 2.5rem;
      border-radius: 16px;
      border: 1px solid var(--border);
      box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
    }
    h1 {
      font-size: 1.875rem;
      font-weight: 700;
      margin-bottom: 0.5rem;
      color: var(--accent);
    }
    .subtitle {
      font-size: 0.875rem;
      color: var(--text-muted);
      margin-bottom: 2rem;
      padding-bottom: 1rem;
      border-bottom: 1px solid var(--border);
    }
    h2 {
      font-size: 1.25rem;
      font-weight: 600;
      margin-top: 1.75rem;
      margin-bottom: 0.75rem;
    }
    p {
      margin-bottom: 1rem;
      color: var(--text);
    }
    ul {
      margin-bottom: 1rem;
      padding-left: 1.5rem;
    }
    li {
      margin-bottom: 0.5rem;
    }
    strong {
      color: var(--text);
    }
    a {
      color: var(--accent);
      text-decoration: none;
    }
    a:hover {
      text-decoration: underline;
    }
    .footer {
      margin-top: 2.5rem;
      padding-top: 1.5rem;
      border-top: 1px solid var(--border);
      font-size: 0.875rem;
      color: var(--text-muted);
      text-align: center;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>Política de Privacidade</h1>
    <div class="subtitle">Capy Energy / Capy Companion • Última atualização: 21 de agosto de 2026</div>

    <p>O aplicativo <strong>Capy</strong> ("Capy Companion") foi projetado com respeito à privacidade e à segurança das suas informações. Esta política descreve de forma clara como os dados são tratados.</p>

    <h2>1. Dados Coletados</h2>
    <ul>
      <li><strong>Informações de Conta (Opcional):</strong> Endereço de e-mail e identificador de autenticação caso você crie ou acesse uma conta de usuário.</li>
      <li><strong>Dados de Telemetria e Veículo:</strong> Histórico de viagens, sessões de recarga, consumo de energia elétrica, potência, nível de bateria (SOC) e odômetro. Esses dados são obtidos diretamente do veículo por comunicação em rede local (Wi-Fi / mDNS).</li>
      <li><strong>Localização (GPS):</strong> Coordenadas geográficas de início e fim de viagens e locais de recarga, utilizadas para identificação dos trajetos e exibição em mapas no aplicativo.</li>
    </ul>

    <h2>2. Finalidade do Uso</h2>
    <p>Os dados coletados são utilizados exclusivamente para:</p>
    <ul>
      <li>Exibir métricas e estatísticas de condução, autonomia e recargas.</li>
      <li>Calcular custos e eficiência energética das suas viagens.</li>
      <li>Permitir a identificação e nomeação de pontos de recarga e destinos frequentes.</li>
      <li>Sincronizar seus dados entre seus dispositivos autorizados.</li>
    </ul>

    <h2>3. Armazenamento e Compartilhamento</h2>
    <ul>
      <li><strong>Armazenamento Local:</strong> O banco de dados principal de telemetria reside localmente no seu dispositivo.</li>
      <li><strong>Nenhum Compartilhamento com Terceiros:</strong> Não vendemos, alugamos nem compartilhamos dados com redes de publicidade ou corretores de dados.</li>
      <li><strong>Serviços de Terceiros:</strong> O aplicativo utiliza o serviço Supabase para gerenciamento seguro de autenticação e OpenStreetMap para renderização visual dos mapas.</li>
    </ul>

    <h2>4. Retenção e Exclusão de Dados</h2>
    <p>Você tem total controle sobre seus registros:</p>
    <ul>
      <li>É possível apagar o histórico armazenado localmente a qualquer momento nas configurações do aplicativo.</li>
      <li>Caso utilize uma conta, você pode solicitar a exclusão definitiva da conta e de todos os dados associados diretamente no aplicativo ou enviando um e-mail para o desenvolvedor.</li>
    </ul>

    <h2>5. Contato</h2>
    <p>Em caso de dúvidas sobre esta Política de Privacidade ou sobre o tratamento dos seus dados, entre em contato:</p>
    <p><strong>E-mail:</strong> <a href="mailto:timoteohss@gmail.com">timoteohss@gmail.com</a></p>

    <div class="footer">
      © 2026 Capy Energy. Todos os direitos reservados.
    </div>
  </div>
</body>
</html>`;

Deno.serve((_req) => {
  return new Response(htmlContent, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=3600",
    },
  });
});

