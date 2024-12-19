# gh-ignore

`gh` extension that creates a .gitignore file from templates from github.com/github/gitignore

## Installation

Prerequisite: [fzf](https://github.com/junegunn/fzf) needs to be installed and in the `$PATH`.

```
gh extension install knutwalker/gh-ignore
```


## Usage


Default usage,

```
gh ignore
```

This will create a new `.gitignore` file with the concatenated content of the selected base files.
The selection of files is done by `fzf`, which run in multi-select mode.
In order to select multiple files, select each of them with <kbd>Tab</kbd>, then commit your total selection with <kbd>Return</kbd>

## Workflow

### Source Repository

On the first run, the repository https://github.com/github/gitignore will be cloned in a cache directory.
The default cache location is printed in the output of `gh ignore --help`

That repository is updated (`git pull`) if the last update was older than a day ago.

Other than the git operations to update the repository, no network requests are done.

### Output File

By default, the result is written to `.gitignore`.
The output can be set with `-o` or `--output`, accepting `-` to mean stdout.
The output file will always be truncated and overwritten if it already exists.

Typically, you would set up the .gitignore file once, at the start of a new repo, and then manually update it over the lifetime of the repo.


## Alternatives

There are a number of .gitignore template tools out there, they differ in:

- Using the [GitHub REST API](https://docs.github.com/en/rest/gitignore/gitignore) on every call instead of a cached repository
- Using a third party source instead of GitHub
- Being a standalone tools instead of a `gh` plugin
- Being a different distribution all together, such as a website

