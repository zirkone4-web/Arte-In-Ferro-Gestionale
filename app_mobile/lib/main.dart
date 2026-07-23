import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: '',
);

const String supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
  defaultValue: '',
);

SupabaseClient get supabase => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (supabaseUrl.isEmpty || supabasePublishableKey.isEmpty) {
    runApp(const ConfigurationErrorApp());
    return;
  }

  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );

  runApp(const ArteInFerroApp());
}

class ArteInFerroApp extends StatelessWidget {
  const ArteInFerroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arte in Ferro ERP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF173B57),
          brightness: Brightness.light,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class UtenteProfilo {
  const UtenteProfilo({
    required this.id,
    required this.nomeCognome,
    required this.email,
    required this.ruolo,
    required this.attivo,
  });

  final String id;
  final String nomeCognome;
  final String email;
  final String ruolo;
  final bool attivo;

  bool get isAdmin => ruolo == 'admin';

  factory UtenteProfilo.fromMap(Map<String, dynamic> map) {
    return UtenteProfilo(
      id: map['id'] as String,
      nomeCognome: map['nome_cognome'] as String,
      email: map['email'] as String,
      ruolo: map['ruolo'] as String,
      attivo: map['attivo'] as bool,
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Session? _session;
  StreamSubscription<AuthState>? _authSubscription;
  int _sessionVersion = 0;

  @override
  void initState() {
    super.initState();

    _session = supabase.auth.currentSession;

    _authSubscription = supabase.auth.onAuthStateChange.listen((authState) {
      if (!mounted) {
        return;
      }

      setState(() {
        _session = authState.session;
        _sessionVersion++;
      });
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;

    if (session == null) {
      return const LoginScreen();
    }

    return ProfiloGate(
      key: ValueKey('${session.user.id}-$_sessionVersion'),
      userId: session.user.id,
    );
  }
}

class ProfiloGate extends StatefulWidget {
  const ProfiloGate({
    required this.userId,
    super.key,
  });

  final String userId;

  @override
  State<ProfiloGate> createState() => _ProfiloGateState();
}

class _ProfiloGateState extends State<ProfiloGate> {
  late Future<UtenteProfilo> _profiloFuture;

  @override
  void initState() {
    super.initState();
    _profiloFuture = _caricaProfilo();
  }

  Future<UtenteProfilo> _caricaProfilo() async {
    final data = await supabase
        .from('utenti')
        .select('id, nome_cognome, email, ruolo, attivo')
        .eq('id', widget.userId)
        .single();

    final profilo = UtenteProfilo.fromMap(data);

    if (!profilo.attivo) {
      await supabase.auth.signOut();
      throw const ProfiloException(
        'Il tuo account è stato disattivato. Contatta un amministratore.',
      );
    }

    return profilo;
  }

  void _riprova() {
    setState(() {
      _profiloFuture = _caricaProfilo();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UtenteProfilo>(
      future: _profiloFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return ProfiloErroreScreen(
            messaggio: _messaggioErroreProfilo(snapshot.error),
            onRiprova: _riprova,
          );
        }

        return MobileHomeScreen(
          profilo: snapshot.data!,
        );
      },
    );
  }

  String _messaggioErroreProfilo(Object? errore) {
    if (errore is ProfiloException) {
      return errore.messaggio;
    }

    if (errore is PostgrestException) {
      return 'Non è stato possibile leggere il profilo utente.\n'
          'Errore database: ${errore.message}';
    }

    return 'Non è stato possibile caricare il profilo utente.';
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _caricamento = false;
  bool _passwordNascosta = true;
  String? _errore;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _accedi() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _caricamento = true;
      _errore = null;
    });

    try {
      await supabase.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on AuthException catch (errore) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errore = _traduciErroreAccesso(errore);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errore = 'Impossibile collegarsi al server. Riprova.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _caricamento = false;
        });
      }
    }
  }

  String _traduciErroreAccesso(AuthException errore) {
    final messaggio = errore.message.toLowerCase();

    if (messaggio.contains('invalid login credentials')) {
      return 'Email o password non corretti.';
    }

    if (messaggio.contains('email not confirmed')) {
      return 'L’indirizzo email non è stato ancora confermato.';
    }

    if (messaggio.contains('too many requests')) {
      return 'Troppi tentativi. Attendi qualche minuto e riprova.';
    }

    return 'Accesso non riuscito: ${errore.message}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: AutofillGroup(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Icon(
                            Icons.precision_manufacturing,
                            size: 72,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Arte In Ferro',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Gestionale dipendenti',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 32),
                          TextFormField(
                            controller: _emailController,
                            enabled: !_caricamento,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [
                              AutofillHints.email,
                              AutofillHints.username,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.email_outlined),
                            ),
                            validator: (valore) {
                              final email = valore?.trim() ?? '';

                              if (email.isEmpty) {
                                return 'Inserisci l’email.';
                              }

                              if (!email.contains('@')) {
                                return 'Inserisci un’email valida.';
                              }

                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _passwordController,
                            enabled: !_caricamento,
                            obscureText: _passwordNascosta,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.password],
                            onFieldSubmitted: (_) => _accedi(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                tooltip: _passwordNascosta
                                    ? 'Mostra password'
                                    : 'Nascondi password',
                                onPressed: () {
                                  setState(() {
                                    _passwordNascosta = !_passwordNascosta;
                                  });
                                },
                                icon: Icon(
                                  _passwordNascosta
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                            validator: (valore) {
                              if (valore == null || valore.isEmpty) {
                                return 'Inserisci la password.';
                              }

                              return null;
                            },
                          ),
                          if (_errore != null) ...[
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .errorContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _errore!,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: _caricamento ? null : _accedi,
                            icon: _caricamento
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(
                              _caricamento ? 'Accesso...' : 'Accedi',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MobileHomeScreen extends StatelessWidget {
  const MobileHomeScreen({
    required this.profilo,
    super.key,
  });

  final UtenteProfilo profilo;

  Future<void> _esci() async {
    await supabase.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Arte In Ferro'),
        actions: [
          IconButton(
            tooltip: 'Esci',
            onPressed: _esci,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    child: Text(
                      _iniziali(profilo.nomeCognome),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profilo.nomeCognome,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(profilo.email),
                        const SizedBox(height: 4),
                        Text(
                          profilo.isAdmin
                              ? 'Amministratore'
                              : 'Operatore',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Funzioni',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ModuloCard(
                icona: Icons.fingerprint,
                titolo: 'Timbrature',
              ),
              ModuloCard(
                icona: Icons.description_outlined,
                titolo: 'Documenti',
              ),
              ModuloCard(
                icona: Icons.local_shipping_outlined,
                titolo: 'Mezzi',
              ),
              ModuloCard(
                icona: Icons.local_gas_station_outlined,
                titolo: 'Rifornimenti',
              ),
              ModuloCard(
                icona: Icons.calendar_month_outlined,
                titolo: 'Planning',
              ),
              ModuloCard(
                icona: Icons.assignment_outlined,
                titolo: 'Rapportini',
              ),
              ModuloCard(
                icona: Icons.report_problem_outlined,
                titolo: 'Ticket anomalie',
              ),
              ModuloCard(
                icona: Icons.inventory_2_outlined,
                titolo: 'Richieste materiale',
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _iniziali(String nomeCognome) {
    final parti = nomeCognome
        .trim()
        .split(RegExp(r'\s+'))
        .where((parte) => parte.isNotEmpty)
        .toList();

    if (parti.isEmpty) {
      return '?';
    }

    if (parti.length == 1) {
      return parti.first.substring(0, 1).toUpperCase();
    }

    return '${parti.first.substring(0, 1)}'
        '${parti.last.substring(0, 1)}'
        .toUpperCase();
  }
}

class ModuloCard extends StatelessWidget {
  const ModuloCard({
    required this.icona,
    required this.titolo,
    super.key,
  });

  final IconData icona;
  final String titolo;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 155,
      height: 125,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$titolo: funzione in preparazione.'),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icona, size: 36),
                const SizedBox(height: 10),
                Text(
                  titolo,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProfiloErroreScreen extends StatelessWidget {
  const ProfiloErroreScreen({
    required this.messaggio,
    required this.onRiprova,
    super.key,
  });

  final String messaggio;
  final VoidCallback onRiprova;

  Future<void> _esci() async {
    await supabase.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      messaggio,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: onRiprova,
                      child: const Text('Riprova'),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _esci,
                      child: const Text('Torna al login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProfiloException implements Exception {
  const ProfiloException(this.messaggio);

  final String messaggio;
}

class ConfigurationErrorApp extends StatelessWidget {
  const ConfigurationErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Configurazione Supabase mancante.\n'
              'Inserire SUPABASE_URL e SUPABASE_PUBLISHABLE_KEY.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
