allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// ── Java 8 廃止警告の抑制（BUG-26 / 2026-08-22 方針変更）──────────────
//
// サードパーティ Flutter プラグイン 7 件が内部で Java 8 ターゲットを指定しており、
// ビルドのたびに javac がこう言ってくる:
//
//     警告: [options] ソース値8は廃止されていて、今後のリリースで削除される予定です
//     警告: [options] ターゲット値8は廃止されていて、今後のリリースで削除される予定です
//
// 対象 (2026-08-22 実測): flutter_local_notifications / flutter_secure_storage /
// permission_handler_android / posthog_flutter / purchases_flutter /
// sentry_flutter / sign_in_with_apple
//
// ## 🔴 旧実装は 1 行も効いていなかった
//
//     subprojects {
//         project.tasks.withType<JavaCompile>().configureEach {
//             sourceCompatibility = JavaVersion.VERSION_11.toString()  // ← 無視される
//         }
//     }
//
// **JavaCompile タスクの source/target を後から代入しても AGP が必ず上書きする。**
// afterEvaluate の中で登録しても、条件を外して無条件に代入しても効かないことを
// 実測で確認済み (代入後も 1.8 のまま / 17 のまま)。
//
// ## なぜ「11 に引き上げる」のをやめたか
//
// AGP 公式の `finalizeDsl` フックなら **設定はできる**。しかし
// `dsl.compileOptions.targetCompatibility` は **どのサブプロジェクトでも読めない**
// (`IllegalStateException: targetCompatibility is not yet finalized`)。
// つまり「現在値が 11 未満のときだけ引き上げる」が書けない。
//
// 一律に 11 を入れると、**すでに 17 を使っているプラグインを降格させてしまう**。
// 実測では connectivity_plus / firebase_* / package_info_plus が 17 で、
// とくに package_info_plus は Kotlin 側が JVM_17 のままなので
// 「Inconsistent JVM-target compatibility detected for tasks
//  'compileReleaseJavaWithJavac' (11) and 'compileReleaseKotlin' (17)」
// でビルドが落ちる。
//
// ## 採った方針
//
// **これは他人のソースに向けられた助言である。** 我々が直せるのはプラグイン作者が
// ターゲットを上げるまでの間の出力ノイズだけで、生成物は 1 バイトも変わらない。
// javac 自身が案内しているとおり `-Xlint:-options` で黙らせる:
//
//     警告: [options] 廃止されたオプションについての警告を表示しないようにするには、
//           -Xlint:オプションを使用します。
//
// `:app` (自分たちのコード) は対象外にして、警告は全部見えるままにしておく。
// 現状 `:app` は自前の build.gradle.kts で Java 11 を明示しているので警告は出ない。
subprojects {
    fun silenceObsoleteOptionsWarning() {
        tasks.withType<JavaCompile>().configureEach {
            // compilerArgs は AGP が消さないリストなので、こちらは追記が効く
            // (source/target の代入と違って上書きされない)。
            options.compilerArgs.add("-Xlint:-options")
        }
    }

    // 上の `evaluationDependsOn(":app")` により **:app だけは既に評価済み**で、
    // そこへ `afterEvaluate` を登録すると Gradle が
    // 「Cannot run Project.afterEvaluate(Action) when the project is already
    //  evaluated.」で落ちる。
    if (path == ":app") return@subprojects
    afterEvaluate { silenceObsoleteOptionsWarning() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
