import chalk from 'chalk';

export const log = {
  banner(text) {
    const line = '─'.repeat(Math.max(text.length + 4, 40));
    console.log(chalk.cyanBright(line));
    console.log(chalk.cyanBright.bold(`  ${text}`));
    console.log(chalk.cyanBright(line));
  },
  stage(n, text) {
    console.log('\n' + chalk.bgCyan.black.bold(` STAGE ${n} `) + ' ' + chalk.bold(text) + '\n');
  },
  info(msg) {
    console.log(chalk.blue('i'), msg);
  },
  success(msg) {
    console.log(chalk.green('✔'), msg);
  },
  warn(msg) {
    console.log(chalk.yellow('!'), msg);
  },
  error(msg) {
    console.log(chalk.red('✖'), msg);
  },
  dim(msg) {
    console.log(chalk.gray(msg));
  },
  heading(msg) {
    console.log(chalk.magentaBright.bold(msg));
  },
  divider() {
    console.log(chalk.gray('─'.repeat(70)));
  },
};
