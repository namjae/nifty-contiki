---
layout: page
permalink: /install/
title: Install Nifty
tags: [about,tutorial]
#image:
#  feature: nifty_process.png
---

## Dependencies
+ Erlang OTP >17.0 
+ **libclang** including the header files (libclang-dev)
+ **clang** compiler

In Ubuntu you can install the dependencies with this command:

{% highlight bash %}
sudo apt-get install libclang-dev libclang1 clang
{% endhighlight %}

Unfortunaley Ubuntu installs ```libclang``` and ```libclang-dev``` in a place that is not
included in the standart search paths. This however can be easily fixed by setting the
some environment variables. The path Ubuntu installs those packages it ```/usr/lib/llvm-<version>```.
If the installed version of the library is 3.4, then we can set the relevant environment variables
as follows:

{% highlight bash %}
export CPATH=/usr/lib/llvm-3.4/include 
export LIBRARY_PATH=/usr/lib/llvm-3.4/lib 
export LD_LIBRARY_PATH=/usr/lib/llvm-3.4/lib
{% endhighlight %}

## Installation
Clone Nifty from the official repository, change to the directory and run make:

{% highlight bash %}
git clone https://github.com/parapluu/nifty.git
cd nifty/
make
{% endhighlight %}

Now include Nifty in your ERL_LIBS path and you are ready to go.
